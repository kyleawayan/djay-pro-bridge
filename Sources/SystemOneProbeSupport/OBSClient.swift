import Foundation
import Network

public enum OBSConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case retrying(String)
    case failed(String)
}

/// Polls OBS's recording position over obs-websocket and reports each round trip.
/// Uses Network.framework rather than URLSession so plain `ws://` to a LAN address is not subject to App Transport Security.
public final class OBSClient: @unchecked Sendable {
    public static let pollInterval: TimeInterval = 1

    private let queue = DispatchQueue(label: "bridge.obs.client", qos: .userInteractive)
    private let url: URL
    private let password: String?
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var retry: DispatchWorkItem?
    private var pending: [String: UInt64] = [:]
    private var nextID = 0
    private var identified = false
    private var stopped = false
    private let clock: @Sendable () -> UInt64

    public var onStatus: (@Sendable (OBSConnectionStatus) -> Void)?
    public var onSample: (@Sendable (OBSSyncSample) -> Void)?
    public var onRecordState: (@Sendable (OBSRecordState) -> Void)?

    public init(host: String, port: Int, password: String?,
                clock: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) throws {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, (1...65535).contains(port), let url = URL(string: "ws://\(trimmed):\(port)") else {
            throw OBSProtocolError("Enter the OBS computer's address and WebSocket port")
        }
        self.url = url
        self.password = password
        self.clock = clock
    }

    public func start() { queue.async { [self] in stopped = false; open() } }

    public func stop() {
        queue.sync {
            stopped = true
            retry?.cancel(); retry = nil
            teardown()
            onStatus?(.disconnected)
        }
    }

    private func open() {
        teardown()
        onStatus?(.connecting)
        let socket = NWProtocolWebSocket.Options()
        socket.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        let connection = NWConnection(to: .url(url), using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, connection === self.connection else { return }
            switch state {
            case .ready: self.receive(on: connection)
            case .waiting(let error): self.onStatus?(.retrying(Self.describe(error)))
            case .failed(let error): self.lost(Self.describe(error))
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func teardown() {
        timer?.cancel(); timer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        pending = [:]; identified = false
    }

    /// Wi-Fi drops are expected on the road; keep retrying until the user disconnects.
    private func lost(_ reason: String) {
        teardown()
        guard !stopped else { return }
        onStatus?(.retrying(reason))
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.open()
        }
        retry = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func fail(_ reason: String) {
        stopped = true
        teardown()
        onStatus?(.failed(reason))
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, context, _, error in
            let now = self?.clock() ?? 0
            guard let self, let connection, connection === self.connection else { return }
            if let error { self.lost(Self.describe(error)); return }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               metadata.opcode == .close {
                self.closed(metadata.closeCode)
                return
            }
            if let data, !data.isEmpty { self.handle(data, receivedNS: now) }
            if self.connection === connection { self.receive(on: connection) }
        }
    }

    private func closed(_ code: NWProtocolWebSocket.CloseCode) {
        if case .privateCode(let value) = code {
            switch value {
            case 4009: fail("OBS rejected the WebSocket password"); return
            case 4010: fail("This OBS version's WebSocket protocol is not supported"); return
            default: lost("OBS closed the connection (code \(value))"); return
            }
        }
        lost("OBS closed the connection")
    }

    private func handle(_ data: Data, receivedNS: UInt64) {
        let message: OBSMessage
        do { message = try OBSProtocol.parse(data) } catch { return }
        switch message {
        case .hello(let challenge, let salt):
            do { send(try OBSProtocol.identify(challenge: challenge, salt: salt, password: password)) }
            catch { fail(error.localizedDescription) }
        case .identified:
            identified = true
            onStatus?(.connected)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        case .recordStatus(let id, let active, let paused, let videoMS):
            guard let sent = pending.removeValue(forKey: id) else { return }
            onSample?(OBSSyncSample(sentNS: sent, receivedNS: receivedNS, active: active, paused: paused, videoMS: videoMS))
        case .requestFailed(let id, _):
            pending[id] = nil
        case .recordStateChanged(let state, let active, let path):
            onRecordState?(OBSRecordState(receivedNS: receivedNS, state: state, active: active, path: path))
        case .other:
            break
        }
    }

    private func poll() {
        guard identified else { return }
        let now = clock()
        // A reply that has not arrived within 5 s is not usable for timing; forget it.
        pending = pending.filter { now &- $0.value < 5_000_000_000 }
        nextID += 1
        let id = "record-status-\(nextID)"
        pending[id] = clock()
        send(OBSProtocol.request("GetRecordStatus", id: id))
    }

    private func send(_ data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "obs", metadata: [metadata])
        connection?.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.lost(Self.describe(error))
        })
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, code == .ECONNREFUSED { return "OBS refused the connection; check that its WebSocket server is enabled" }
        // Local Network privacy denials surface as ENETDOWN even when Wi-Fi is up.
        if case .posix(let code) = error, code == .ENETDOWN {
            return "macOS blocked local network access. Allow the app that launched this debugger in System Settings → Privacy & Security → Local Network"
        }
        return error.localizedDescription
    }
}
