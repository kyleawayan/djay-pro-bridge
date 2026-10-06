import CoreMIDI
import Foundation

/// Create, start and stop on the main thread. Message callbacks arrive on the capture queue.
public final class MIDIProbeSession {
    public private(set) var endpointNames: [String: String] = [:]
    public var onStop: ((Bool, String) -> Void)?
    public var directory: URL { capture.directory }
    private let endpointName: String
    private let identity: String
    private let capture: Capture
    private var client: MIDIClientRef = 0
    private var source: MIDIEndpointRef = 0
    private var destination: MIDIEndpointRef = 0
    private var stopped = false
    private var started = false
    public private(set) var startupKeepaliveSent = false

    public init(endpointName: String, identity: String, verbose: Bool = false,
                onWarning: ((String) -> Void)? = nil, onMessage: ((CapturedMessage) -> Void)? = nil) throws {
        self.endpointName = endpointName
        self.identity = identity
        capture = try Capture(verbose: verbose, onMessage: onMessage, onWarning: onWarning)
    }

    public func start(seconds: Int) throws {
        guard !started && !stopped && (1...600).contains(seconds) else {
            throw TransportError("Invalid duration or session already used")
        }
        started = true
        do {
            try checkForCollisions(endpointName)
            try check(MIDIClientCreate("Bridge Telemetry Probe" as CFString, nil, nil, &client), "MIDIClientCreate")
            // A receiver must exist before source creation can trigger native discovery.
            try check(MIDIDestinationCreateWithBlock(client, endpointName as CFString, &destination) { [capture] packets, _ in
                capture.receive(packets)
            }, "MIDIDestinationCreateWithBlock")
            try check(MIDISourceCreate(client, endpointName as CFString, &source), "MIDISourceCreate")
            for (label, endpoint) in [("source", source), ("destination", destination)] {
                endpointNames[label + "_name"] = property(endpoint, kMIDIPropertyName) ?? "unavailable"
                endpointNames[label + "_display_name"] = property(endpoint, kMIDIPropertyDisplayName) ?? "unavailable"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self] in self?.stop(reason: "duration") }
        } catch {
            stopped = true
            _ = cleanup()
            _ = capture.finish(identity: identity, reason: "startup_error", endpointNames: endpointNames)
            throw error
        }
    }

    public func sendStartupKeepalive() throws {
        guard started, !stopped, source != 0 else { throw TransportError("Session is not connected") }
        guard !startupKeepaliveSent else { return }
        let bytes = StartupKeepalive.frame()
        var list = MIDIPacketList()
        let capacity = MemoryLayout<MIDIPacketList>.size
        let status: OSStatus = bytes.withUnsafeBufferPointer { buffer in
            withUnsafeMutablePointer(to: &list) { pointer in
                let packet = MIDIPacketListInit(pointer)
                _ = MIDIPacketListAdd(pointer, capacity, packet, 0, bytes.count, buffer.baseAddress!)
                return MIDIReceived(source, pointer)
            }
        }
        try check(status, "MIDIReceived on the probe's own virtual source")
        startupKeepaliveSent = true
        capture.recordTransmission(bytes)
    }

    private func cleanup() -> Bool {
        var succeeded = true
        if source != 0 { succeeded = MIDIEndpointDispose(source) == noErr && succeeded; source = 0 }
        if destination != 0 { succeeded = MIDIEndpointDispose(destination) == noErr && succeeded; destination = 0 }
        if client != 0 { succeeded = MIDIClientDispose(client) == noErr && succeeded; client = 0 }
        return succeeded
    }

    public func stop(reason: String = "user") {
        guard !stopped else { return }
        stopped = true
        let disposed = cleanup()
        let saved = capture.finish(identity: identity, reason: reason, endpointNames: endpointNames)
        onStop?(saved && disposed, disposed ? reason : "cleanup_error")
    }

    deinit {
        if !stopped {
            _ = cleanup()
            _ = capture.finish(identity: identity, reason: "released", endpointNames: endpointNames)
        }
    }
}
