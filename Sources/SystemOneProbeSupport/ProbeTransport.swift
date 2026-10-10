import CoreMIDI
import Foundation

struct TransportError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

public struct CapturedMessage: Sendable {
    public let receivedClockNS: UInt64
    public let sequence: Int
    public let elapsedSeconds: Double
    public let bytes: [UInt8]
    public let packets: Int
    public let receivedBytes: Int
    public let droppedPackets: Int
    public let transmittedBytes: Int

    public init(sequence: Int, elapsedSeconds: Double, bytes: [UInt8], packets: Int, receivedBytes: Int, droppedPackets: Int, transmittedBytes: Int = 0, receivedClockNS: UInt64 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) {
        self.receivedClockNS = receivedClockNS
        self.sequence = sequence
        self.elapsedSeconds = elapsedSeconds
        self.bytes = bytes
        self.packets = packets
        self.receivedBytes = receivedBytes
        self.droppedPackets = droppedPackets
        self.transmittedBytes = transmittedBytes
    }
}

func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw TransportError("\(operation) failed with OSStatus \(status)") }
}

func property(_ endpoint: MIDIEndpointRef, _ key: CFString) -> String? {
    var value: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(endpoint, key, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

func checkForCollisions(_ targetName: String) throws {
    let pattern = #"(?i)rane system one \w+ [12]$"#
    for isSource in [true, false] {
        let count = isSource ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations()
        for index in 0..<count {
            let endpoint = isSource ? MIDIGetSource(index) : MIDIGetDestination(index)
            for key in [kMIDIPropertyName, kMIDIPropertyDisplayName] {
                guard let name = property(endpoint, key) else { continue }
                if name == targetName || name.range(of: pattern, options: .regularExpression) != nil {
                    throw TransportError("A probe or SYSTEM ONE endpoint already exists. Close the other probe or disconnect that controller before retrying. No endpoints were created.")
                }
            }
        }
    }
}

final class Capture: @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "system-one-probe.capture")
    private let gate = NSLock()
    private var accepting = true
    private var pendingBytes = 0
    private var pendingPackets = 0
    private let recordTraffic: Bool
    private let maximumPendingBytes: Int
    private var acceptedBytes = 0
    private var acceptedPackets = 0
    private var droppedPackets = 0
    private let started = DispatchTime.now().uptimeNanoseconds
    private let handle: FileHandle?
    private var framer = SysExFramer()
    private var messages = 0
    private var candidateMessages = 0
    private var transmittedBytes = 0
    private var malformedMessages = 0
    private var writeError: String?
    private var finished = false
    private let onMessage: ((CapturedMessage) -> Void)?
    private let verbose: Bool
    private let onWarning: ((String) -> Void)?

    init(verbose: Bool = true, recordTraffic: Bool = true, maximumPendingBytes: Int = 8 * 1_048_576, onMessage: ((CapturedMessage) -> Void)? = nil, onWarning: ((String) -> Void)? = nil) throws {
        self.recordTraffic = recordTraffic
        self.maximumPendingBytes = maximumPendingBytes
        self.verbose = verbose
        self.onMessage = onMessage
        self.onWarning = onWarning
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-one-probe-\(UUID().uuidString)", isDirectory: true)
        for parent in ancestorDirectories(of: directory.deletingLastPathComponent().resolvingSymlinksInPath()) {
            if FileManager.default.fileExists(atPath: parent.appendingPathComponent(".git").path) {
                throw TransportError("Temporary output would be inside a Git checkout. Set TMPDIR to a private directory outside the repository.")
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        if recordTraffic {
            let url = directory.appendingPathComponent("traffic.ndjson")
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw TransportError("Cannot create local traffic log")
            }
            handle = try FileHandle(forWritingTo: url)
        } else { handle = nil }

    }

    func receive(_ packets: UnsafePointer<MIDIPacketList>) {
        // CoreMIDI lists contain variable-sized packets; copying the Swift tuple truncates long ones.
        let firstOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet)!
        let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data)!
        var packet = UnsafeRawPointer(packets).advanced(by: firstOffset).assumingMemoryBound(to: MIDIPacket.self)
        for _ in 0..<packets.pointee.numPackets {
            let count = Int(packet.pointee.length)
            gate.lock()
            // Bound pending work, never the lifetime of a session.
            if accepting && pendingBytes + count <= maximumPendingBytes && pendingPackets < 100_000 {
                acceptedBytes += count
                acceptedPackets += 1
                pendingBytes += count
                pendingPackets += 1
                let data = Data(bytes: UnsafeRawPointer(packet).advanced(by: dataOffset), count: count)
                let timestamp = packet.pointee.timeStamp
                let receivedClock = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
                // Submission stays inside the gate so finish cannot overtake an accepted packet.
                queue.async {
                    self.record(data, midiTimestamp: timestamp, elapsed: elapsed, recordTraffic: self.recordTraffic, receivedClock: receivedClock)
                    self.gate.lock()
                    self.pendingBytes -= count
                    self.pendingPackets -= 1
                    self.gate.unlock()
                }
            } else if accepting {
                droppedPackets += 1
            }
            gate.unlock()
            packet = UnsafePointer(MIDIPacketNext(packet))
        }
    }

    private func write(_ record: [String: Any]) {
        guard writeError == nil, let handle else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(0x0a)
            try handle.write(contentsOf: data)
        } catch {
            writeError = "Traffic log write failed: \(error.localizedDescription)"
            onWarning?("Traffic log write failed. Live values may continue, but the saved recording is incomplete.")
        }
    }

    private func record(_ bytes: Data, midiTimestamp: MIDITimeStamp, elapsed: Double, recordTraffic: Bool, receivedClock: UInt64) {
        if recordTraffic {
            write(["kind": "packet", "elapsed_seconds": elapsed,
                   "midi_timestamp": String(midiTimestamp), "length": bytes.count, "hex": hex(bytes)])
        }
        for event in framer.consume(bytes) {
            switch event {
            case .message(let message):
                messages += 1
                let candidate = message.count >= 3 && message[1] == 0x70
                if candidate { candidateMessages += 1 }
                if recordTraffic {
                    write(["kind": "sysex", "elapsed_seconds": elapsed, "length": message.count,
                           "short_id_70_candidate": candidate, "hex": hex(message)])
                }
                gate.lock()
                let packetCount = acceptedPackets
                let byteCount = acceptedBytes
                let dropped = droppedPackets
                gate.unlock()
                onMessage?(CapturedMessage(sequence: messages, elapsedSeconds: elapsed, bytes: message, packets: packetCount, receivedBytes: byteCount, droppedPackets: dropped, transmittedBytes: transmittedBytes, receivedClockNS: receivedClock))
                if verbose && messages <= 10 {
                    print("SysEx \(messages): \(message.count) bytes; \(hex(message.prefix(16)))\(message.count > 16 ? " …" : "")\(candidate ? " [0x70 candidate; not handshake proof]" : "")")
                }
            case .interrupted(let count), .oversized(let count):
                malformedMessages += 1
                if recordTraffic { write(["kind": "discarded_partial_sysex", "length": count]) }
            }
        }
    }

    func recordTransmission(_ bytes: [UInt8]) {
        queue.async {
            guard !self.finished else { return }
            self.transmittedBytes += bytes.count
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - self.started) / 1_000_000_000
            self.write(["kind": "transmit", "elapsed_seconds": elapsed, "length": bytes.count,
                        "purpose": "single startup keepalive", "hex": hex(bytes)])
        }
    }

    func drain() { queue.sync {} }

    // Order recording boundaries after accepted messages without waiting for another SysEx.
    func withSynchronizedDropCount<T>(_ operation: (Int) throws -> T) rethrows -> T {
        try queue.sync {
            gate.lock()
            let dropped = droppedPackets
            gate.unlock()
            return try operation(dropped)
        }
    }

    func finish(identity: String, reason: String, endpointNames: [String: String]) -> Bool {
        gate.lock()
        accepting = false
        let packets = acceptedPackets
        let bytes = acceptedBytes
        let dropped = droppedPackets
        gate.unlock()
        return queue.sync {
            guard !finished else { return writeError == nil && dropped == 0 }
            finished = true
            var summary: [String: Any] = [
                "identity": identity, "stop_reason": reason, "own_endpoints": endpointNames,
                "packet_count": packets, "byte_count": bytes, "sysex_count": messages,
                "short_id_70_candidates": candidateMessages, "discarded_partial_messages": malformedMessages,
                "unfinished_sysex_bytes": framer.partial.count, "dropped_packets": dropped,
                "transmitted_bytes": transmittedBytes,
                "raw_recording_enabled": recordTraffic,
                "interpretation": "Raw capture counters only. Use the schema decoder to classify message contents; silence remains inconclusive."
            ]
            if let writeError { summary["log_error"] = writeError }
            do {
                try handle?.synchronize()
                try handle?.close()
                let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                let url = directory.appendingPathComponent("summary.json")
                try data.write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { writeError = "Could not finish logs: \(error.localizedDescription)" }
            if verbose {
            print("Stopped: \(packets) packets, \(messages) SysEx messages, \(candidateMessages) candidate 0x70 messages. Sent: \(transmittedBytes) bytes.")
            if dropped > 0 { print("Capture queue overflow: \(dropped) packets omitted. Results are incomplete.") }
            if framer.partial.count > 0 { print("Capture ended with an incomplete SysEx message.") }
            if let writeError { print(writeError) }
            print("Local logs: \(directory.path)")
            print("Share summary.json first. Raw traffic may contain track metadata; keep it local.")
            }
            return writeError == nil && dropped == 0
        }
    }
}
