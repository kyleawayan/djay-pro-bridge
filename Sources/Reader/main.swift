import DjayBridge
import Foundation

// MARK: - Parse arguments

var logMode = false
var renderIntervalMs: UInt32 = 33  // ~30fps default
var wsPort: UInt16 = 9090

let args = CommandLine.arguments
if let idx = args.firstIndex(of: "--interval"), idx + 1 < args.count,
   let ms = UInt32(args[idx + 1]) {
    renderIntervalMs = ms
}
if let idx = args.firstIndex(of: "--ws-port"), idx + 1 < args.count,
   let p = UInt16(args[idx + 1]) {
    wsPort = p
}
if args.contains("--log") {
    logMode = true
}
var serialPort: String? = nil
if let idx = args.firstIndex(of: "--serial-port"), idx + 1 < args.count {
    serialPort = args[idx + 1]
}

// MARK: - Find djay Pro and check permissions

guard let djay = findDjayPro() else { exit(1) }
guard checkAccessibilityPermission(djay.element) else { exit(1) }

printError("🎧 Rendering at ~\(1000 / max(renderIntervalMs, 1))fps, polling AX in background... (Ctrl+C to stop)\n")

// MARK: - MIDI

let kontrolX1 = KontrolX1()
let xoneK2 = XoneK2WithCustomMAX7219()

// MARK: - OSC

let oscSender = OSCSender(host: "127.0.0.1", port: 9001)

// MARK: - Serial display

let serialDisplay: SerialDisplay? = serialPort.flatMap { SerialDisplay(port: $0) }
if let port = serialPort {
    if serialDisplay != nil {
        printError("📟 Serial display on \(port)")
    } else {
        printError("⚠️  Failed to open serial port \(port)")
    }
}

// MARK: - Serial display state (driven by K2 MIDI + AX sync)

if let display = serialDisplay {
    let displayLock = NSLock()
    var bj: [Int: String] = [1: "1", 2: "1"]
    var lp: [Int: String] = [1: "4", 2: "4"]
    var lpOn: [Int: Bool] = [1: false, 2: false]

    func sendDisplayState() {
        display.sendState(
            bj1: bj[1]!, lp1: lp[1]!, lp2: lp[2]!, bj2: bj[2]!,
            loop1On: lpOn[1]!, loop2On: lpOn[2]!
        )
    }

    xoneK2.onBeatJumpChanged = { deck, label in
        displayLock.lock()
        bj[deck] = label
        displayLock.unlock()
        sendDisplayState()
    }
    xoneK2.onLoopChanged = { deck, label in
        displayLock.lock()
        lp[deck] = label
        displayLock.unlock()
        sendDisplayState()
    }
    xoneK2.onLoopToggled = { deck, isOn in
        displayLock.lock()
        lpOn[deck] = isOn
        displayLock.unlock()
        sendDisplayState()
    }
    xoneK2.onModifierChanged = { isHeld in
        if isHeld {
            let (d1, d2, _, _, _, _, _, _) = state.snapshot()
            if let p1 = d1.bpmPercent, let p2 = d2.bpmPercent {
                let pct1 = p1.replacingOccurrences(of: "%", with: "")
                let pct2 = p2.replacingOccurrences(of: "%", with: "")
                let w1 = pct1.filter({ $0 != "." }).count
                let w2 = pct2.filter({ $0 != "." }).count
                let left = String(repeating: " ", count: max(0, 4 - w1)) + pct1
                let right = String(repeating: " ", count: max(0, 4 - w2)) + pct2
                display.sendOverlay("\(left)\(right)")
            }
        } else {
            display.clearOverlay()
        }
    }
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
    private var _lastSentBeatJump1: String? = nil
    private var _lastSentBeatJump2: String? = nil
    private var _lastSentCrossfader: String? = nil
    private var _lastSentKey: String? = nil
    private var _lastMainDeck: Int? = nil

    func updateFromAX(deck1: DeckInfo, deck2: DeckInfo, crossfader: String?) {
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
            isPlaying: d1.isPlaying, bpmPercent: d1.bpmPercent
        )
        _interp2.update(
            elapsedTime: d2.elapsedTime, remainingTime: d2.remainingTime,
            isPlaying: d2.isPlaying, bpmPercent: d2.bpmPercent
        )

        var midiPayloads: [(deck: Int, value: String)] = []
        if deck1.beatJump != _lastSentBeatJump1, let bj = deck1.beatJump {
            _lastSentBeatJump1 = bj
            midiPayloads.append((deck: 1, value: bj))
        }
        if deck2.beatJump != _lastSentBeatJump2, let bj = deck2.beatJump {
            _lastSentBeatJump2 = bj
            midiPayloads.append((deck: 2, value: bj))
        }

        var crossfaderChanged: String? = nil
        if crossfader != _lastSentCrossfader, let cf = crossfader {
            _lastSentCrossfader = cf
            crossfaderChanged = cf
        }

        // Send OSC when the main deck's key changes
        var oscPayload: (rootNoteIndex: Int, scale: String)? = nil
        let mainKey: String?
        switch _mainDeck {
        case 1: mainKey = deck1.key
        case 2: mainKey = deck2.key
        default: mainKey = nil
        }
        if let key = mainKey, (key != _lastSentKey || _mainDeck != _lastMainDeck) {
            _lastSentKey = key
            if let parsed = ParsedKey.parse(key) {
                oscPayload = (parsed.rootNoteIndex, parsed.scale)
            }
        }
        _lastMainDeck = _mainDeck

        lock.unlock()

        for payload in midiPayloads {
            kontrolX1.sendBeatJump(deck: payload.deck, value: payload.value)
            printError("MIDI: CC \(payload.deck == 1 ? 24 : 25) = \(payload.value)")
        }
        if let cf = crossfaderChanged {
            kontrolX1.sendCrossfader(value: cf)
            printError("MIDI: CC 29 = \(cf)")
        }
        if let payload = oscPayload {
            oscSender.sendKeyChange(rootNoteIndex: payload.rootNoteIndex, scale: payload.scale)
            printError("OSC: /root-key-change \(payload.rootNoteIndex), /scale-name-change \(payload.scale)")
        }

        // Sync K2 display from AX
        if let bj = deck1.beatJump { xoneK2.syncBeatJump(deck: 1, value: bj) }
        if let bj = deck2.beatJump { xoneK2.syncBeatJump(deck: 2, value: bj) }
        if let ls = deck1.loopSize { xoneK2.syncLoop(deck: 1, value: ls) }
        if let ls = deck2.loopSize { xoneK2.syncLoop(deck: 2, value: ls) }
        xoneK2.syncLoopActive(deck: 1, isActive: deck1.isLooping)
        xoneK2.syncLoopActive(deck: 2, isActive: deck2.isLooping)
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

// MARK: - WebSocket server

let wsServer = try WebSocketServer(port: wsPort)

let jsonEncoder: JSONEncoder = {
    let enc = JSONEncoder()
    enc.keyEncodingStrategy = .convertToSnakeCase
    return enc
}()

struct BroadcastPayload: Codable {
    var deck1: DeckInfo
    var deck2: DeckInfo
    var crossfader: String?
    var mainDeck: Int?
}

// MARK: - AX polling thread

let pollQueue = DispatchQueue(label: "ax-poll", qos: .userInitiated)
pollQueue.async {
    while true {
        let deck1 = getDeckInfo(app: djay.element, deckNumber: 1)
        let deck2 = getDeckInfo(app: djay.element, deckNumber: 2)
        let crossfader = getCrossfader(app: djay.element)
        state.updateFromAX(deck1: deck1, deck2: deck2, crossfader: crossfader)

        // Update tempo % overlay while modifier is held
        if xoneK2.isModifierHeld, let display = serialDisplay {
            if let p1 = deck1.bpmPercent, let p2 = deck2.bpmPercent {
                let pct1 = p1.replacingOccurrences(of: "%", with: "")
                let pct2 = p2.replacingOccurrences(of: "%", with: "")
                let w1 = pct1.filter({ $0 != "." }).count
                let w2 = pct2.filter({ $0 != "." }).count
                let left = String(repeating: " ", count: max(0, 4 - w1)) + pct1
                let right = String(repeating: " ", count: max(0, 4 - w2)) + pct2
                display.sendOverlay("\(left)\(right)")
            }
        }

        usleep(50_000) // 50ms backoff to avoid overwhelming AX API over long sessions
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

    // Broadcast state over WebSocket
    var d1ws = deck1
    var d2ws = deck2
    d1ws.elapsedTime = e1.map { TimeInterpolator.format($0) }
    d1ws.remainingTime = r1.map { TimeInterpolator.format($0, negative: true) }
    d2ws.elapsedTime = e2.map { TimeInterpolator.format($0) }
    d2ws.remainingTime = r2.map { TimeInterpolator.format($0, negative: true) }
    let payload = BroadcastPayload(deck1: d1ws, deck2: d2ws, crossfader: crossfader, mainDeck: mainDeck)
    if let data = try? jsonEncoder.encode(payload) {
        wsServer.broadcast(data)
    }

    fflush(stdout)
    usleep(renderIntervalMs * 1000)
}
