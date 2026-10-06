import CoreMIDI
import Darwin
import Foundation
import SystemOneProbeSupport

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Options {
    var identity = "generic"
    var seconds = 15
    var confirmsEmptyDecks = false
    var acceptsDeckChanges = false
    var startupKeepalive = false

    var endpointName: String {
        identity == "generic" ? "Bridge Telemetry Probe Port 2" : "Rane SYSTEM ONE Port 2"
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var result = Options()
        var args = ArraySlice(arguments)
        while let arg = args.popFirst() {
            switch arg {
            case "--identity":
                guard let value = args.popFirst(), ["generic", "system-one-display"].contains(value) else {
                    throw ProbeError("--identity requires generic or system-one-display")
                }
                result.identity = value
            case "--seconds":
                guard let value = args.popFirst(), let seconds = Int(value), (1...120).contains(seconds) else {
                    throw ProbeError("--seconds requires an integer from 1 to 120")
                }
                result.seconds = seconds
            case "--startup-keepalive": result.startupKeepalive = true
            case "--confirm-empty-decks": result.confirmsEmptyDecks = true
            case "--accept-deck-changes": result.acceptsDeckChanges = true
            default: throw ProbeError("Unknown option: \(arg). Run with --help.")
            }
        }
        if result.identity != "generic" && !result.confirmsEmptyDecks && !result.acceptsDeckChanges {
            throw ProbeError("SYSTEM ONE recognition can unload tracks or change djay routing. Use --confirm-empty-decks for an idle, empty session, or --accept-deck-changes to explicitly accept unloading/routing changes with loaded decks.")
        }
        return result
    }
}


final class Probe {
    private let options: Options
    private var session: MIDIProbeSession?
    private var signalSources: [DispatchSourceSignal] = []
    private var families: [UInt64: Int] = [:]
    private var assembler = MessageAssembler()

    init(options: Options) { self.options = options }

    func start() throws {
        let session = try MIDIProbeSession(endpointName: options.endpointName, identity: options.identity, verbose: true, onMessage: { [weak self] message in
            DispatchQueue.main.async { [weak self] in self?.received(message) }
        })
        self.session = session
        session.onStop = { saved, _ in exit(saved ? 0 : 1) }
        try session.start(seconds: options.seconds)
        print("Listening for \(options.seconds) seconds: \(options.endpointName)")
        print(options.startupKeepalive ? "One peer-identification keepalive will be sent after djay identification. No playback or browsing commands." : "Passive capture: no messages sent.")
        print("Capture directory: \(session.directory.path)")
        for key in session.endpointNames.keys.sorted() { print("\(key): \(session.endpointNames[key]!)") }
        print("Press Ctrl-C to remove the temporary pair early.")
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let signalSource = DispatchSource.makeSignalSource(signal: number, queue: .main)
            signalSource.setEventHandler { [weak session] in session?.stop(reason: "signal") }
            signalSource.resume()
            signalSources.append(signalSource)
        }
    }
    private func received(_ message: CapturedMessage) {
        guard let frame = assembler.consume(message.bytes, time: message.elapsedSeconds).frame else { return }
        let packet = PacketDebugger.inspect(frame, catalog: nil)
        if let field = packet.field {
            families[field, default: 0] += 1
            if families[field] == 1 { print("New received protobuf family \(field), \(frame.count) bytes; payload omitted") }
        }
        if options.startupKeepalive, packet.field == 1, let session, !session.startupKeepaliveSent {
            do {
                try session.sendStartupKeepalive()
                print("Sent one schema-defined startup keepalive (\(StartupKeepalive.frame().count) bytes).")
            } catch { print("Startup keepalive failed: \(error)"); session.stop(reason: "handshake_error") }
        }
    }
}

if CommandLine.arguments.dropFirst().contains("--help") {
    print("""
    Usage: SystemOneProbe [--identity generic|system-one-display] [--seconds 15] [--confirm-empty-decks | --accept-deck-changes] [--startup-keepalive]

    Default: a neutral source/destination pair, listening for 15 seconds.
    SYSTEM ONE mode uses Rane SYSTEM ONE Port 2. Recognition can unload tracks or change routing.
    Use --confirm-empty-decks for an idle session with every deck empty.
    --accept-deck-changes explicitly permits testing with loaded decks despite possible unloading/routing changes.
    --startup-keepalive sends exactly one schema-defined peer identification after receiving djay identification.
    Default mode sends nothing. No playback/browsing commands or USB identity emulation.
    Logs stay in a private temporary directory outside Git. Existing endpoints are not modified.
    --help creates no MIDI client or endpoints.
    """)
    exit(0)
}

do {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    let probe = Probe(options: options)
    try probe.start()
    withExtendedLifetime(probe) { dispatchMain() }
} catch {
    FileHandle.standardError.write(Data("SystemOneProbe: \(error)\n".utf8))
    exit(1)
}
