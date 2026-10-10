import AppKit
import Combine
import Foundation
import SystemOneProbeSupport
import UniformTypeIdentifiers

struct HistoryPoint: Identifiable {
    let id: Int
    let time: Double
    let position: Double?
    let rate: Double?
}

struct MessageRow: Identifiable {
    let id: Int
    let time: Double
    let kind: String
    let field: UInt64?
    let bytes: Int
}

struct StreamState {
    var telemetry: RealtimeTelemetry?
    var history: [HistoryPoint] = []
    var lastTime: Double?
    var lastReceived: Date?
    var gaps: [Double] = []
    var updates = 0
}

struct InspectorState {
    var messages = 0
    var packets = 0
    var bytes = 0
    var dropped = 0
    var transmittedBytes = 0
    var overview = OverviewState()
    var images = 0
    var imageBytes = 0
    var unknown = 0
    var malformed = 0
    var identification = 0
    var version: String?
    var streams: [UInt32: StreamState] = [:]
    var recent: [MessageRow] = []
    var types: [String: Int] = [:]
    var lastMessage: Date?
    var elapsed: Double = 0
    var store = PacketStore()
}

@MainActor
final class InspectorModel: ObservableObject {
    @Published var state = InspectorState()
    @Published var phase = "Disconnected"
    @Published var error: String?
    @Published var identity = "system-one-display"
    @Published var recordingParent = UserDefaults.standard.string(forKey: "telemetry.recordingFolder").map { URL(fileURLWithPath: $0) }
    @Published var recordingDirectory: URL?
    @Published var recording = false
    @Published var recordingStatus = "Not recording"
    private let recorder = TelemetryRecorder()
    @Published var selectedType: UInt64 = 51
    @Published var selectedScope: PacketScope = .deck(0)
    @Published var selectedImageIndex: UInt32 = 0
    @Published var freezeDisplay = false {
        didSet { uiUpdates.isPaused = freezeDisplay }
    }
    @Published var startupStatus = "Not connected"
    @Published var schemaStatus = "Reading installed app schema…"
    @Published private var schemaLoading = true
    private var catalog: ProtocolCatalog?
    private var assembler = MessageAssembler()
    @Published var logDirectory: URL?
    @Published var endpointNames: [String: String] = [:]
    @Published var now = Date()
    private var session: MIDIProbeSession?
    private var token = UUID()
    private var buffer = InspectorState()
    private lazy var uiUpdates = CoalescedUpdate(schedule: { action in
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0) { action() }
    }) { [weak self] in
        guard let self else { return }
        self.state = self.buffer
        self.now = Date()
    }
    private var timer: AnyCancellable?

    var connected: Bool { session != nil }
    var busy: Bool { schemaLoading || connected || phase == "Loading capture" || phase == "Connecting" }
    var activeStream: StreamState? {
        guard case .deck(let index) = selectedScope else { return nil }
        return state.streams[index]
    }
    var scopes: [PacketScope] { Array(Set(state.store.latest.keys).union([.global, .deck(0), .deck(1)])).sorted() }
    var scopedPackets: [UInt64: PacketSnapshot] { state.store.latest[selectedScope] ?? [:] }
    var selectedPacket: PacketSnapshot? {
        if selectedScope == .global && selectedType == 90, let image = state.store.images[selectedImageIndex] { return image }
        return scopedPackets[selectedType]
    }
    var canConnect: Bool { !busy }

    init(schemaLoader: ((@escaping (Result<ProtocolCatalog, Error>) -> Void) -> Void)? = nil) {
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] date in
            guard let self else { return }
            if self.recording {
                let status = self.recorder.status
                self.recordingStatus = status.error ?? ByteCountFormatter.string(fromByteCount: Int64(status.bytes), countStyle: .file)
            }
            self.now = date
        }
        if let schemaLoader {
            schemaLoader { [weak self] result in self?.finishSchemaLoading(result) }
            return
        }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.algoriddim.djay-iphone-free") {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try ProtocolCatalog.load(app: app) }
                DispatchQueue.main.async { [weak self] in
                    self?.finishSchemaLoading(result)
                }
            }
        } else {
            schemaStatus = "Installed djay app not found; numeric decoding available"
            schemaLoading = false
        }
    }

    private func finishSchemaLoading(_ result: Result<ProtocolCatalog, Error>) {
        defer { schemaLoading = false }
        switch result {
        case .success(let catalog):
            self.catalog = catalog
            schemaStatus = "\(catalog.messages.count) message schemas · \(catalog.filename)"
        case .failure:
            schemaStatus = "Embedded schema unavailable; numeric decoding remains available"
        }
    }

    func connect() {
        guard canConnect else { return }
        reset()
        recorder.reset()
        phase = "Connecting"
        startupStatus = identity == "system-one-display" ? "Waiting for djay identification" : "Passive comparison"
        let currentToken = token
        let recorder = self.recorder
        let recordingCatalog = self.catalog
        DispatchQueue.main.async { [weak self] in
            guard let self, self.token == currentToken else { return }
            do {
                let endpoint = self.identity == "generic" ? "Bridge Telemetry Probe Port 2" : "Rane SYSTEM ONE Port 2"
                let session = try MIDIProbeSession(endpointName: endpoint, identity: self.identity, recordTraffic: false, onWarning: { [weak self] warning in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.token == currentToken else { return }
                        self.error = warning
                    }
                }) { [weak self] message in
                    recorder.consume(message, catalog: recordingCatalog)
                    let decoded = SystemOneDecoder.decode(message.bytes)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.token == currentToken else { return }
                        self.receive(message, decoded: decoded)
                        if self.identity == "system-one-display", case .identification = decoded,
                           let session = self.session, !session.startupKeepaliveSent {
                            do {
                                try session.sendStartupKeepalive()
                                self.startupStatus = "Startup identification sent"
                            } catch {
                                self.error = String(describing: error)
                                session.stop(reason: "handshake_error")
                            }
                        }
                    }
                }
                self.session = session
                session.onStop = { [weak self] saved, reason in
                    guard let self, self.token == currentToken else { return }
                    self.stopRecording()
                    self.session = nil
                    self.phase = saved ? "Stopped · \(reason == "duration" ? "time limit" : "disconnected")" : "Stopped with error"
                    if !saved { self.error = "Log finalization or MIDI cleanup failed. Inspect the local summary before reconnecting." }
                }
                self.logDirectory = session.directory
                try session.start(seconds: nil)
                self.endpointNames = session.endpointNames
                self.phase = "Listening"
            } catch {
                self.session = nil
                self.phase = "Connection failed"
                self.error = String(describing: error)
            }
        }
    }

    func stop() { session?.stop() }

    func startRecording() {
        guard let session, !recording else { return }
        guard catalog != nil else { error = "Recording requires the installed djay schema. Reopen after schema loading succeeds."; return }
        if recordingParent == nil { chooseRecordingFolder() }
        guard let parent = recordingParent else { return }
        let folder = parent.appendingPathComponent("session-" + UUID().uuidString)
        do {
            try session.startRecording(recorder, at: folder)
            recordingDirectory = folder
            recording = true
            recordingStatus = "Recording"
        } catch { self.error = error.localizedDescription }
    }

    func chooseRecordingFolder() {
        guard !recording else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for telemetry sessions"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = recordingParent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recordingParent = url
        UserDefaults.standard.set(url.path, forKey: "telemetry.recordingFolder")
    }

    func stopRecording() {
        guard recording else { return }
        do {
            if let session { try session.stopRecording(recorder) } else { try recorder.stop() }
            recordingStatus = "Saved"
        }
        catch { self.error = error.localizedDescription; recordingStatus = "Incomplete recording" }
        recording = false
    }

    private func reset() {
        token = UUID()
        assembler = MessageAssembler()
        uiUpdates.cancelPending()
        freezeDisplay = false
        state = InspectorState()
        buffer = state
        error = nil
        endpointNames = [:]
        logDirectory = nil
        selectedScope = .deck(0)
        selectedImageIndex = 0
    }

    private func receive(_ message: CapturedMessage, decoded initialDecoded: DecodedMessage) {
        let assembly = assembler.consume(message.bytes, time: message.elapsedSeconds)
        let decodedFrame = assembly.frame ?? message.bytes
        let decoded = assembly.frame.map(SystemOneDecoder.decode) ?? initialDecoded
        let packet = PacketDebugger.inspect(decodedFrame, catalog: catalog)
        buffer.store.record(raw: message.bytes, decodedFrame: decodedFrame, packet: packet,
                            elapsed: message.elapsedSeconds, assembly: assembly.status)
        buffer.overview.consume(packet)
        buffer.messages += 1
        buffer.packets = message.packets
        buffer.bytes = message.receivedBytes
        buffer.dropped = message.droppedPackets
        buffer.transmittedBytes = message.transmittedBytes
        buffer.elapsed = message.elapsedSeconds
        buffer.lastMessage = Date()
        buffer.types[packet.name, default: 0] += 1
        switch decoded {
        case .realtime(let data):
            guard let key = packet.deckIndex else { break }
            var stream = buffer.streams[key] ?? StreamState()
            if let previous = stream.lastTime, message.elapsedSeconds >= previous {
                stream.gaps.append(message.elapsedSeconds - previous)
                if stream.gaps.count > 200 { stream.gaps.removeFirst(stream.gaps.count - 200) }
            }
            stream.telemetry = data
            stream.lastTime = message.elapsedSeconds
            stream.lastReceived = Date()
            stream.updates += 1
            if message.elapsedSeconds - (stream.history.last?.time ?? -1) >= 0.1 {
                stream.history.append(HistoryPoint(id: message.sequence, time: message.elapsedSeconds, position: data.position, rate: data.rate))
                if stream.history.count > 600 { stream.history.removeFirst(stream.history.count - 600) }
            }
            buffer.streams[key] = stream
        case .identification(let version): buffer.identification += 1; buffer.version = version ?? buffer.version
        case .image(let bytes, _): buffer.images += 1; buffer.imageBytes += bytes
        case .unknown: buffer.unknown += 1
        case .malformed: buffer.malformed += 1
        }
        buffer.recent.append(MessageRow(id: message.sequence, time: message.elapsedSeconds, kind: decoded.title, field: decoded.field, bytes: message.bytes.count))
        if buffer.recent.count > 80 { buffer.recent.removeFirst(buffer.recent.count - 80) }
        uiUpdates.request()
    }

    func chooseCapture() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Inspect a private probe capture"
        panel.message = "Choose traffic.ndjson to inspect its received packets and decoded fields."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { loadCapture(url) }
    }

    func loadCapture(_ url: URL) {
        guard !busy else { return }
        reset()
        phase = "Loading capture"
        let currentToken = token
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 64 * 1_048_576 else {
                    throw InspectorError("Capture exceeds the 64 MiB inspection limit")
                }
                let text = try String(contentsOf: url, encoding: .utf8)
                var packets = 0, byteCount = 0, transmittedBytes = 0
                var messages: [(CapturedMessage, DecodedMessage)] = []
                for line in text.split(whereSeparator: \.isNewline) {
                    guard let data = line.data(using: .utf8),
                          let record = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if record["kind"] as? String == "transmit" { transmittedBytes = try CaptureCounters.add(record["length"], to: transmittedBytes) }
                    if record["kind"] as? String == "packet" {
                        packets += 1
                        byteCount = try CaptureCounters.add(record["length"], to: byteCount)
                    }
                    guard record["kind"] as? String == "sysex",
                          let hex = record["hex"] as? String,
                          let elapsed = record["elapsed_seconds"] as? Double, elapsed.isFinite else { continue }
                    let components = hex.split(separator: " ")
                    let bytes = components.compactMap { UInt8($0, radix: 16) }
                    guard bytes.count == components.count, messages.count < 100_000 else { throw InspectorError("Invalid or oversized capture") }
                    let message = CapturedMessage(sequence: messages.count + 1, elapsedSeconds: elapsed, bytes: bytes,
                                                  packets: packets, receivedBytes: byteCount, droppedPackets: 0, transmittedBytes: transmittedBytes)
                    messages.append((message, SystemOneDecoder.decode(bytes)))
                }
                guard !messages.isEmpty else { throw InspectorError("No complete SysEx records found in this capture") }
                let captured = messages
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.token == currentToken else { return }
                    for (message, decoded) in captured { self.receive(message, decoded: decoded) }
                    self.uiUpdates.flushNow()
                    self.phase = "Saved capture · offline"
                    self.startupStatus = self.buffer.transmittedBytes > 0 ? "Capture includes startup identification" : "Passive capture"
                    self.logDirectory = url.deletingLastPathComponent()
                }
            } catch {
                let description = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.token == currentToken else { return }
                    self.phase = "Could not open capture"
                    self.error = description
                }
            }
        }
    }
}

struct InspectorError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
