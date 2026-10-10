import Foundation
import CryptoKit

/// Serializes received state independently of display refresh and debug capture limits.
public final class TelemetryRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bridge.session.writer", qos: .utility)
    private let gate = NSLock()
    private var pending = 0
    private var dropped = 0
    private var assembler = MessageAssembler()
    private var overview = OverviewState()
    private var recordedArtwork: [UInt32: Data] = [:]
    private var handle: FileHandle?
    private var directory: URL?
    private var origin: UInt64 = 0
    private var createdAt = Date()
    private let now: @Sendable () -> Date
    private var buffer = Data()
    private var previous: [UInt32: Data] = [:]
    private var failure: String?
    private var lastFlush = Date()
    private var bytesWritten = 0
    private var timer: DispatchSourceTimer?
    private var transportDropped = 0
    public var onFailure: (@Sendable (String) -> Void)?

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        self.timer = timer
    }

    public func consume(_ message: CapturedMessage, catalog: ProtocolCatalog?) {
        gate.lock()
        if pending + message.bytes.count > 8 * 1_048_576 {
            dropped += 1
            gate.unlock()
            return
        }
        pending += message.bytes.count
        gate.unlock()
        queue.async { [self] in
            defer { gate.lock(); pending -= message.bytes.count; gate.unlock() }
            if message.droppedPackets > transportDropped {
                transportDropped = message.droppedPackets
                if handle != nil { fail(RecorderError("Incoming transport dropped telemetry; recording is incomplete")) }
            }
            let assembly = assembler.consume(message.bytes, time: message.elapsedSeconds)
            guard let frame = assembly.frame else { return }
            let packet = PacketDebugger.inspect(frame, catalog: catalog)
            overview.consume(packet)
            guard handle != nil else { return }
            let t = Double(message.receivedClockNS >= origin ? message.receivedClockNS - origin : 0) / 1e9
            do {
                if let index = packet.deckIndex, let deck = overview.decks[index] {
                    if packet.field == 55 { emit(["kind": "clear", "t": t, "deck": index]) }
                    writeDeck(index, deck: deck, time: t)
                    try writeArtwork(index, deck: deck, time: t)
                    if packet.field == 63 { writeGrid(index, deck: deck, time: t) }
                    if let samples = packet.waveform, let offset = packet.waveformOffset {
                        emit(["kind": "waveform", "t": t, "deck": index, "offset": offset,
                              "asset": try asset(Data(samples), ext: "bin")])
                    }
                }
            } catch { fail(error) }
        }
    }

    public func reset() {
        queue.sync {
            guard handle == nil else { return }
            assembler = MessageAssembler(); overview = OverviewState(); recordedArtwork = [:]; transportDropped = 0
        }
    }

    public func start(at directory: URL, transportDroppedPackets: Int? = nil) throws {
        try queue.sync {
            guard handle == nil else { throw RecorderError("Recording already active") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            self.directory = directory
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("assets"), withIntermediateDirectories: false)
            let events = directory.appendingPathComponent("events.ndjson")
            guard FileManager.default.createFile(atPath: events.path, contents: nil) else { throw RecorderError("Cannot create events file") }
            handle = try FileHandle(forWritingTo: events)
            origin = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            createdAt = now()
            if let transportDroppedPackets { transportDropped = transportDroppedPackets }
            failure = nil; previous = [:]; recordedArtwork = [:]; buffer = Data(); bytesWritten = 0
            gate.lock(); dropped = 0; gate.unlock()
            do {
                try manifest(complete: false)
                for (index, deck) in overview.decks {
                    writeDeck(index, deck: deck, time: 0)
                    try writeArtwork(index, deck: deck, time: 0)
                    writeGrid(index, deck: deck, time: 0)
                    for (offset, samples) in deck.detailChunks {
                        emit(["kind": "waveform", "t": 0, "deck": index, "offset": offset,
                              "asset": try asset(Data(samples), ext: "bin")])
                    }
                }
                flush()
                if let failure { throw RecorderError(failure) }
            } catch { try? handle?.close(); handle = nil; throw error }
        }
    }

    public func stop(transportDroppedPackets: Int? = nil) throws {
        try queue.sync {
            guard handle != nil else { return }
            if let transportDroppedPackets, transportDroppedPackets > transportDropped {
                transportDropped = transportDroppedPackets
                fail(RecorderError("Incoming transport dropped telemetry; recording is incomplete"))
            }
            flush()
            do { try handle?.synchronize(); try handle?.close() }
            catch { fail(error); try? handle?.close() }
            handle = nil
            gate.lock(); let omitted = dropped; gate.unlock()
            if omitted > 0 { failure = "\(omitted) incoming messages omitted; session is incomplete" }
            try manifest(complete: failure == nil)
            if let failure { throw RecorderError(failure) }
        }
    }

    public var status: (bytes: Int, error: String?) {
        queue.sync {
            gate.lock(); let omitted = dropped; gate.unlock()
            return (bytesWritten + buffer.count, failure ?? (omitted > 0 ? "Incoming telemetry was dropped" : nil))
        }
    }

    private func writeDeck(_ index: UInt32, deck: DeckOverview, time: Double) {
        let state: [String: Any] = ["title": deck.title, "artist": deck.artist,
            "duration": deck.duration as Any? ?? NSNull(), "position": deck.position as Any? ?? NSNull(),
            "rate": deck.velocity as Any? ?? NSNull(), "bpm": deck.tempo as Any? ?? NSNull(), "key": deck.key,
            "artIndex": deck.artIndex as Any? ?? NSNull(), "loaded": deck.loaded,
            "loopEnabled": deck.loopEnabled,
            "loopRegions": deck.loopRegions.keys.sorted().compactMap { key -> [String: Any]? in
                guard let region = deck.loopRegions[key] else { return nil }
                return ["index": key, "start": region.start, "end": region.end, "status": region.status]
            }]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), previous[index] != data else { return }
        previous[index] = data
        emit(["kind": "deck", "t": time, "deck": index, "state": state])
    }

    private func writeArtwork(_ index: UInt32, deck: DeckOverview, time: Double) throws {
        guard let image = deck.artwork else {
            if recordedArtwork.removeValue(forKey: index) != nil {
                emit(["kind": "deck-artwork", "t": time, "deck": index, "asset": NSNull()])
            }
            return
        }
        guard recordedArtwork[index] != image else { return }
        recordedArtwork[index] = image
        emit(["kind": "deck-artwork", "t": time, "deck": index, "asset": try asset(image, ext: "jpg")])
    }

    private func writeGrid(_ index: UInt32, deck: DeckOverview, time: Double) {
        guard let sampleRate = deck.sampleRate, sampleRate.isFinite, deck.trackStart.isFinite else { return }
        let anchors = deck.beatGrid.filter { $0.positionInSamples.isFinite }.map {
            ["positionInSamples": $0.positionInSamples, "positionInBeats": Double($0.positionInBeats)]
        }
        emit(["kind": "beatgrid", "t": time, "deck": index,
              "beatGrid": ["sampleRate": sampleRate, "trackStart": deck.trackStart, "anchors": anchors]])
    }

    private func asset(_ data: Data, ext: String) throws -> String {
        let name = "assets/" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "." + ext
        let url = directory!.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        return name
    }

    private func emit(_ event: [String: Any]) {
        guard failure == nil else { return }
        do {
            buffer.append(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
            buffer.append(10)
            if buffer.count >= 64 * 1024 || Date().timeIntervalSince(lastFlush) >= 1 { flush() }
        } catch { fail(error) }
    }

    private func flush() {
        guard let handle, !buffer.isEmpty, failure == nil else { return }
        do {
            try handle.write(contentsOf: buffer)
            bytesWritten += buffer.count
            buffer.removeAll(keepingCapacity: true)
            lastFlush = Date()
        } catch { fail(error) }
    }

    private func manifest(complete: Bool) throws {
        guard let directory else { return }
        let data: [String: Any] = ["version": 1, "clock": "monotonic-ns", "clock_origin_ns": String(origin), "clock_source": "CLOCK_UPTIME_RAW",
            "created_at": ISO8601DateFormatter().string(from: createdAt), "events": "events.ndjson",
            "waveform_samples_per_second": 315, "complete": complete, "error": failure as Any? ?? NSNull()]
        try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }
    private func fail(_ error: Error) { if failure == nil { failure = error.localizedDescription; onFailure?(failure!) }; buffer.removeAll() }
    deinit { timer?.cancel(); try? handle?.close() }
}

public struct RecorderError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
