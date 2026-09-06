import DjayBridge
import Foundation

// MARK: - Parse arguments

var logMode = false
var renderIntervalMs: UInt32 = 33  // ~30fps default
var artnetHost: String? = nil
var artnetPort: UInt16 = 6454  // Art-Net default port
var artnetFramerate: ArtNetTimecodeSender.Framerate = .smpte30

let args = CommandLine.arguments
if let idx = args.firstIndex(of: "--interval"), idx + 1 < args.count,
   let ms = UInt32(args[idx + 1]) {
    renderIntervalMs = ms
}
if args.contains("--log") {
    logMode = true
}
if let idx = args.firstIndex(of: "--artnet-ip"), idx + 1 < args.count {
    artnetHost = args[idx + 1]
}
if let idx = args.firstIndex(of: "--artnet-port"), idx + 1 < args.count,
   let p = UInt16(args[idx + 1]) {
    artnetPort = p
}
if let idx = args.firstIndex(of: "--fps"), idx + 1 < args.count {
    guard let fr = ArtNetTimecodeSender.Framerate.parse(args[idx + 1]) else {
        printError("Invalid --fps '\(args[idx + 1])'. Use 24, 25, 29.97, or 30.")
        exit(1)
    }
    artnetFramerate = fr
}

// MARK: - Find djay Pro and check permissions

guard let djay = findDjayPro() else { exit(1) }
guard checkAccessibilityPermission(djay.element) else { exit(1) }

printError("🎧 Rendering at ~\(1000 / max(renderIntervalMs, 1))fps, polling AX in background... (Ctrl+C to stop)\n")

// MARK: - Art-Net timecode

let artnetSender: ArtNetTimecodeSender? = artnetHost.map {
    printError("📡 Art-Net timecode → \($0):\(artnetPort)\n")
    return ArtNetTimecodeSender(host: $0, port: artnetPort, framerate: artnetFramerate)
}

// MARK: - Thread-safe shared state

class SharedState {
    private let lock = NSLock()
    private var _deck1 = DeckInfo()
    private var _deck2 = DeckInfo()
    private var _crossfader: String? = nil
    private var _mainDeck: Int? = nil
    private var _interp1 = TimeInterpolator()
    private var _interp2 = TimeInterpolator()
    private let _tracker = MainDeckTracker()
    private var _playDebounce1 = PlayStateDebouncer()
    private var _playDebounce2 = PlayStateDebouncer()

    func updateFromAX(
        deck1: DeckInfo, deck2: DeckInfo, crossfader: String?,
        sampleTime1: Date, sampleTime2: Date
    ) {
        lock.lock()
        var d1 = deck1
        var d2 = deck2
        d1.isPlaying = _playDebounce1.update(isPlaying: deck1.isPlaying)
        d2.isPlaying = _playDebounce2.update(isPlaying: deck2.isPlaying)
        _deck1 = d1
        _deck2 = d2
        _crossfader = crossfader
        _mainDeck = _tracker.update(deck1: d1, deck2: d2, crossfader: crossfader)
        _interp1.update(
            elapsedTime: d1.elapsedTime, remainingTime: d1.remainingTime,
            isPlaying: d1.isPlaying, bpmPercent: d1.bpmPercent, sampleTime: sampleTime1
        )
        _interp2.update(
            elapsedTime: d2.elapsedTime, remainingTime: d2.remainingTime,
            isPlaying: d2.isPlaying, bpmPercent: d2.bpmPercent, sampleTime: sampleTime2
        )
        lock.unlock()
    }

    func snapshot() -> (DeckInfo, DeckInfo, Double?, Double?, Double?, Double?, String?, Int?) {
        lock.lock()
        let d1 = _deck1
        let d2 = _deck2
        let e1 = _interp1.interpolatedElapsed()
        let r1 = _interp1.interpolatedRemaining()
        let e2 = _interp2.interpolatedElapsed()
        let r2 = _interp2.interpolatedRemaining()
        let cf = _crossfader
        let main = _mainDeck
        lock.unlock()
        return (d1, d2, e1, r1, e2, r2, cf, main)
    }
}

let state = SharedState()

// MARK: - AX polling thread

let pollQueue = DispatchQueue(label: "ax-poll", qos: .userInitiated)
pollQueue.async {
    while true {
        // Stamp each deck's time at its read instant, not after the whole scan,
        // so the interpolation baseline excludes the AX-scan latency.
        let sampleTime1 = Date()
        let deck1 = getDeckInfo(app: djay.element, deckNumber: 1)
        let sampleTime2 = Date()
        let deck2 = getDeckInfo(app: djay.element, deckNumber: 2)
        let crossfader = getCrossfader(app: djay.element)
        state.updateFromAX(
            deck1: deck1, deck2: deck2, crossfader: crossfader,
            sampleTime1: sampleTime1, sampleTime2: sampleTime2
        )
        // No sleep — poll as fast as AX allows (~8fps)
    }
}

// MARK: - SIGINT handler

signal(SIGINT) { _ in
    if !logMode {
        print("\u{1B}[?25h", terminator: "") // show cursor
    }
    fflush(stdout)
    exit(0)
}

// MARK: - Rendering helpers

func formatTime(elapsed: Double?, remaining: Double?) -> String {
    let elStr = elapsed.map { TimeInterpolator.format($0) } ?? "--:--.~-"
    let remStr = remaining.map { TimeInterpolator.format($0, negative: true) } ?? "--:--.~-"
    return "\(elStr) / \(remStr)"
}

func formatDeck(_ n: Int, _ deck: DeckInfo, elapsed: Double?, remaining: Double?, isMain: Bool) -> String {
    var lines: [String] = []
    let playIcon = deck.isPlaying ? "▶" : "⏸"
    let mainTag = isMain ? " [MAIN]" : ""
    lines.append("Deck \(n) \(playIcon)\(mainTag)")
    lines.append("  \(deck.title ?? "—")")
    lines.append("  \(deck.artist ?? "—")")
    lines.append("  Key: \(deck.key ?? "—")")

    let bpmStr = deck.bpm ?? "—"
    let pctStr = deck.bpmPercent ?? "0.0%"
    let timeStr = formatTime(elapsed: elapsed, remaining: remaining)
    lines.append("  BPM: \(bpmStr) (\(pctStr)) | \(timeStr)")

    lines.append("  Vol: \(deck.lineVolume ?? "—")")

    if elapsed == nil && remaining == nil {
        lines.append("  (no time available — use jog wheel view or toggle timer)")
        lines.append("  (see README for more info)")
    } else if elapsed == nil {
        lines.append("  (elapsed time not available — toggle timer or use jog wheel view)")
        lines.append("  (see README for more info)")
    } else if remaining == nil {
        lines.append("  (remaining time not available — toggle timer or use jog wheel view)")
        lines.append("  (see README for more info)")
    }

    return lines.joined(separator: "\n")
}

// MARK: - Render loop (main thread)

if !logMode {
    // Clear screen, hide cursor
    print("\u{1B}[2J\u{1B}[H\u{1B}[?25l", terminator: "")
}

while true {
    let (deck1, deck2, e1, r1, e2, r2, crossfader, mainDeck) = state.snapshot()

    // Send the main deck's interpolated elapsed time as Art-Net timecode.
    if let sender = artnetSender {
        let mainElapsed: Double?
        switch mainDeck {
        case 1: mainElapsed = e1
        case 2: mainElapsed = e2
        default: mainElapsed = nil
        }
        if let elapsed = mainElapsed {
            sender.send(seconds: elapsed)
        }
    }

    if logMode {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let e1Str = e1.map { TimeInterpolator.format($0) } ?? "--:--.~-"
        let r1Str = r1.map { TimeInterpolator.format($0, negative: true) } ?? "--:--.~-"
        let e2Str = e2.map { TimeInterpolator.format($0) } ?? "--:--.~-"
        let r2Str = r2.map { TimeInterpolator.format($0, negative: true) } ?? "--:--.~-"
        let mainStr = mainDeck.map { "Deck \($0)" } ?? "None"

        print("[\(timestamp)] Main: \(mainStr)")
        print("  Deck 1: \(deck1.title ?? "—") by \(deck1.artist ?? "—") | Key: \(deck1.key ?? "—") | BPM: \(deck1.bpm ?? "—") (\(deck1.bpmPercent ?? "0.0%")) | \(e1Str) / \(r1Str) | \(deck1.isPlaying ? "▶" : "⏸") | Vol: \(deck1.lineVolume ?? "—")")
        print("  Deck 2: \(deck2.title ?? "—") by \(deck2.artist ?? "—") | Key: \(deck2.key ?? "—") | BPM: \(deck2.bpm ?? "—") (\(deck2.bpmPercent ?? "0.0%")) | \(e2Str) / \(r2Str) | \(deck2.isPlaying ? "▶" : "⏸") | Vol: \(deck2.lineVolume ?? "—")")
        print("  Crossfader: \(crossfader ?? "—")")
        print("")
    } else {
        print("\u{1B}[H\u{1B}[J", terminator: "")
        print("djay Pro Bridge\n")
        print(formatDeck(1, deck1, elapsed: e1, remaining: r1, isMain: mainDeck == 1))
        print("")
        print(formatDeck(2, deck2, elapsed: e2, remaining: r2, isMain: mainDeck == 2))
        print("\nCrossfader: \(crossfader ?? "—")")
    }

    fflush(stdout)
    usleep(renderIntervalMs * 1000)
}
