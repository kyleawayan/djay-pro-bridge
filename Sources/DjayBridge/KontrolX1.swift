import CoreMIDI
import Foundation

/// Bidirectional MIDI proxy between the Traktor Kontrol X1 MK2 hardware and djay Pro.
///
/// djay talks only to the virtual "DjayBridge" port; the bridge owns the X1 connection and
/// forwards traffic both directions, intercepting the few controls that need logic. Phase 1
/// is a transparent forward (plus the AX-driven displays the bridge already generated).
public class KontrolX1 {
    private var client = MIDIClientRef()
    private var x1OutPort = MIDIPortRef()
    private var x1InPort = MIDIPortRef()
    private var x1Output: MIDIEndpointRef?         // X1 hardware output (displays + fwd feedback)
    private var virtualSource = MIDIEndpointRef()  // bridge → djay
    private var virtualDest = MIDIEndpointRef()    // djay → bridge (feedback + state)

    private static let x1OutputName = "Traktor Kontrol X1 MK2 - 1 Output"
    private static let x1InputName = "Traktor Kontrol X1 MK2 - 1 Input"
    // The virtual port djay talks to. djay only ever sees "DjayBridge"; the X1 is connected to
    // the bridge, not djay.
    private static let virtualPortName = "DjayBridge"
    // Fixed unique IDs so djay's mappings survive bridge restarts.
    private static let virtualSourceID: Int32 = 0x1D1A0001
    private static let virtualDestID: Int32 = 0x1D1A0002

    // Display CCs the bridge generates itself (from AX) — never forward djay's output on these.
    // 24/25 = main digit, 68/69 = shift display (mirrors the main one).
    private static let ownedDisplayCCs: Set<UInt8> = [24, 25, 68, 69]

    // Beat-jump label → display CC value (X1 shows the CC value verbatim).
    private static let beatJumpOrder: [(label: String, cc: UInt8)] = [
        ("1/32", 0), ("1/16", 116), ("1/8", 118), ("1/4", 114), ("1/2", 112),
        ("1", 1), ("2", 2), ("4", 4), ("8", 8), ("16", 16), ("32", 32), ("64", 64), ("128", 127),
    ]

    // Coupling: on push the bridge fires one of these notes to djay (bound in the mapping to
    // autoLoop<size>BeatInterval / autoLoopOnOff). Free notes, above the X1's used range.
    // All of djay's auto-loop durations (matches beatJumpOrder). suffix = djay keyPath suffix.
    private static let autoLoopSizes: [(label: String, suffix: String)] = [
        ("1/32", "003125"), ("1/16", "00625"), ("1/8", "0125"), ("1/4", "025"), ("1/2", "05"),
        ("1", "1"), ("2", "2"), ("4", "4"), ("8", "8"), ("16", "16"), ("32", "32"),
        ("64", "64"), ("128", "128"),
    ]
    private static let autoLoopBaseNote: [Int: UInt8] = [1: 90, 2: 104]  // 13 notes each: 90-102 / 104-116
    private static let autoLoopOnOffNotes: [Int: UInt8] = [1: 117, 2: 118]

    static func autoLoopSizeNote(deck: Int, size label: String) -> UInt8? {
        guard let idx = autoLoopSizes.firstIndex(where: { $0.label == label }) else { return nil }
        return (autoLoopBaseNote[deck] ?? 96) + UInt8(idx)
    }
    static func autoLoopOnOffNote(_ deck: Int) -> UInt8 { autoLoopOnOffNotes[deck] ?? 112 }
    static func deckForAutoLoopOnOffNote(_ note: UInt8) -> Int? {
        if note == autoLoopOnOffNotes[1] { return 1 }
        if note == autoLoopOnOffNotes[2] { return 2 }
        return nil
    }

    private let lock = NSLock()
    private var deckPosition: [Int: Int] = [1: 5, 2: 5]  // index into beatJumpOrder
    private var lastRotaryTime: [Int: CFAbsoluteTime] = [:]
    private static let rotaryCooldown: CFAbsoluteTime = 0.5  // let the prediction lead over lagging AX
    private var loopActive: [Int: Bool] = [1: false, 2: false]
    private var flashOn = true
    private var flashTimer: DispatchSourceTimer?
    private let flashQueue = DispatchQueue(label: "loop-flash")
    private static let flashInterval: TimeInterval = 0.3
    // Sync-hold mode (KA-272): hold SYNC → encoders become tempo adjust + digits show BPM %.
    private var syncHeld: [Int: Bool] = [1: false, 2: false]
    private var syncPressTime: [Int: CFAbsoluteTime] = [:]
    private var lastTempoMag: [Int: UInt8] = [:]   // cached BPM % magnitude per deck
    private var lastTempoSign: [Int: Int] = [:]    // cached tempo sign (-1/0/+1) per deck
    private static let syncTapThreshold: CFAbsoluteTime = 0.25  // ≤ this = a tap (normal sync)
    // X1 SYNC button notes (bpmSync) and the CCs we emit for speedRelative in sync mode.
    private static let syncNotes: [Int: UInt8] = [1: 40, 2: 41]
    private static func speedRelativeCC(_ deck: Int) -> UInt8 { deck == 1 ? 70 : 71 }
    // Loop resize: a CC the X1 never sends (bridge-driven), bound to autoLoopDurationRotary.
    private static func autoLoopDurationCC(_ deck: Int) -> UInt8 { deck == 1 ? 72 : 73 }
    // Live state model fed by djay's MIDI-out: key (status<<8 | data1) → last value.
    private var feedbackState: [UInt16: UInt8] = [:]

    public init() {
        guard MIDIClientCreate("DjayBridge" as CFString, nil, nil, &client) == noErr else {
            printError("KontrolX1: MIDIClientCreate failed"); return
        }
        guard MIDIOutputPortCreate(client, "x1out" as CFString, &x1OutPort) == noErr else {
            printError("KontrolX1: output port failed"); return
        }

        // Find the X1 hardware output (we drive its displays + forward djay's LED feedback).
        for i in 0..<MIDIGetNumberOfDestinations() {
            let ep = MIDIGetDestination(i)
            if endpointName(ep) == Self.x1OutputName { x1Output = ep; break }
        }
        if x1Output == nil { printError("KontrolX1: '\(Self.x1OutputName)' not found") }
        else { printError("KontrolX1: found \(Self.x1OutputName)") }

        // Listen to the X1 hardware input and forward it to djay.
        guard MIDIInputPortCreate(client, "x1in" as CFString, x1InputCallback, Unmanaged.passUnretained(self).toOpaque(), &x1InPort) == noErr else {
            printError("KontrolX1: input port failed"); return
        }
        for i in 0..<MIDIGetNumberOfSources() {
            let ep = MIDIGetSource(i)
            if endpointName(ep) == Self.x1InputName {
                MIDIPortConnectSource(x1InPort, ep, nil)
                printError("KontrolX1: listening on \(Self.x1InputName)")
                break
            }
        }

        // Virtual "DjayBridge" port (fixed IDs). Source = bridge→djay; destination = djay→bridge.
        if MIDISourceCreate(client, Self.virtualPortName as CFString, &virtualSource) == noErr {
            MIDIObjectSetIntegerProperty(virtualSource, kMIDIPropertyUniqueID, Self.virtualSourceID)
        }
        if MIDIDestinationCreate(client, Self.virtualPortName as CFString, djayOutputCallback, Unmanaged.passUnretained(self).toOpaque(), &virtualDest) == noErr {
            MIDIObjectSetIntegerProperty(virtualDest, kMIDIPropertyUniqueID, Self.virtualDestID)
        }
        printError("KontrolX1: virtual port '\(Self.virtualPortName)' ready")
        clearX1LEDs()
    }

    deinit {
        clearX1LEDs()  // leave the controller dark when the bridge stops
        MIDIClientDispose(client)
    }

    /// Reset the X1 to a known state on startup/shutdown: all button LEDs off (djay's feedback
    /// re-lights whatever's actually active), digits blanked.
    private func clearX1LEDs() {
        guard let x1Output else { return }
        for note in UInt8(0)...127 { send([0x90, note, 0], to: x1Output) }  // all LEDs off
        for cc: UInt8 in [24, 25, 68, 69] { send([0xB0, cc, 0], to: x1Output) }  // blank digits
    }

    // MARK: - AX-driven displays (called from Reader)

    /// Sync the beat-jump display (CC 24/25) to the AX-reported value — but defer to the live
    /// encoder prediction for `rotaryCooldown` after a turn, since AX lags ~8fps and would
    /// otherwise flicker the digit back to a stale value mid-dial.
    public func sendBeatJump(deck: Int, value: String) {
        guard let cc = Self.ccForLabel(value) else { return }
        lock.lock()
        let synced = (syncHeld[1] ?? false) || (syncHeld[2] ?? false)
        let cooldown = (CFAbsoluteTimeGetCurrent() - (lastRotaryTime[deck] ?? 0)) < Self.rotaryCooldown
        if !cooldown, let idx = Self.indexForLabel(value) { deckPosition[deck] = idx }
        lock.unlock()
        if synced { return }  // sync held → digit shows BPM %
        if !cooldown { sendDigit(deck, cc) }
    }

    /// Tempo/pitch % magnitude — shown on the digits only while SYNC is held (otherwise the
    /// digits show beat jump). Cached so a SYNC press can show it immediately.
    public func setTempoPercent(deck: Int, percent: String) {
        guard let val = Double(percent.replacingOccurrences(of: "%", with: "")) else { return }
        let mag = UInt8(min(max(abs(val).rounded(), 0), 127))
        let sign = val > 0 ? 1 : (val < 0 ? -1 : 0)
        lock.lock()
        lastTempoMag[deck] = mag
        lastTempoSign[deck] = sign
        let synced = (syncHeld[1] ?? false) || (syncHeld[2] ?? false)
        lock.unlock()
        if synced { sendDigit(deck, mag); showTempoSignOnFX(deck: deck) }
    }

    // MARK: - Proxy

    /// X1 hardware → djay.
    fileprivate func handleX1Input(_ bytes: [UInt8]) {
        guard bytes.count == 3 else { emitToDjay(bytes); return }
        let status = bytes[0] & 0xF0

        // SYNC button (Note 40/41): tap = normal sync, hold = tempo-adjust mode.
        if bytes[1] == 40 || bytes[1] == 41, status == 0x90 || status == 0x80 {
            let deck = bytes[1] == 40 ? 1 : 2
            if status == 0x90, bytes[2] > 0 { handleSyncPress(deck: deck) }
            else { handleSyncRelease(deck: deck) }
            return  // consume
        }

        // Encoder turn (CC 24/25).
        if status == 0xB0, bytes[1] == 24 || bytes[1] == 25 {
            let deck = bytes[1] == 24 ? 1 : 2
            if syncModeActive() {
                // Sync held → tempo adjust.
                let cc = Self.speedRelativeCC(deck)
                emitToDjay([0xB0, cc, bytes[2]])
                printError("KontrolX1: sync tempo deck \(deck) → CC \(cc) = \(bytes[2])")
            } else if isLoopActive(deck) {
                // Loop running → resize the loop AND beat jump together (they started equal, so
                // they track). autoLoopDurationRotary lives on a bridge-only CC (72/73).
                emitToDjay(bytes)                                          // skipDurationRotary
                emitToDjay([0xB0, Self.autoLoopDurationCC(deck), bytes[2]])  // autoLoopDurationRotary
                predictBeatJumpDisplay(cc: bytes[1], value: bytes[2])
            } else {
                emitToDjay(bytes)  // skipDurationRotary (beat jump)
                predictBeatJumpDisplay(cc: bytes[1], value: bytes[2])
            }
            return
        }

        // Loop encoder push (Note 26/27): consume; start an auto-loop at the current beat-jump
        // size (watched from AX), or exit if already looping.
        if bytes[1] == 26 || bytes[1] == 27, status == 0x90 || status == 0x80 {
            if status == 0x90, bytes[2] > 0 { handleLoopPush(deck: bytes[1] == 26 ? 1 : 2) }
            return  // never forward the raw push
        }

        emitToDjay(bytes)
    }

    // MARK: - Sync-hold mode

    /// Sync-hold is a *global* mode: holding either deck's SYNC shows BPM % on both digits and
    /// retasks both loop encoders to tempo. No deck selection needed.
    private func syncModeActive() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (syncHeld[1] ?? false) || (syncHeld[2] ?? false)
    }

    private func handleSyncPress(deck: Int) {
        lock.lock()
        syncHeld[deck] = true
        syncPressTime[deck] = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        showBpmOnBothDigits()
        showTempoSignOnFX(deck: 1)  // FX buttons show +/- (suspends any railroad blink)
        showTempoSignOnFX(deck: 2)
    }

    private func handleSyncRelease(deck: Int) {
        lock.lock()
        syncHeld[deck] = false
        let tap = (CFAbsoluteTimeGetCurrent() - (syncPressTime[deck] ?? 0)) < Self.syncTapThreshold
        let stillActive = (syncHeld[1] ?? false) || (syncHeld[2] ?? false)
        lock.unlock()
        // Quick tap = normal sync: re-emit bpmSync for that deck.
        if tap, let note = Self.syncNotes[deck] {
            emitToDjay([0x90, note, 127]); emitToDjay([0x90, note, 0])
        }
        // Last SYNC released → restore digits, and the FX buttons (railroad if looping, else off).
        if !stillActive {
            restoreBeatJumpOnBothDigits()
            for d in [1, 2] {
                if isLoopActive(d) {
                    lock.lock(); let f = flashOn; lock.unlock()
                    sendFlashFrame(deck: d, on: f)
                } else {
                    turnOffLoopFlashLEDs(deck: d)
                }
            }
        }
    }

    /// While sync is held, the FX buttons show the tempo sign: left LED = negative, right =
    /// positive, both off at 0%.
    private func showTempoSignOnFX(deck: Int) {
        guard let x1Output, let leds = Self.loopFlashLEDs[deck] else { return }
        lock.lock(); let sign = lastTempoSign[deck] ?? 0; lock.unlock()
        for n in leds.a { send([0x90, n, sign < 0 ? 127 : 0], to: x1Output) }  // left = negative
        for n in leds.b { send([0x90, n, sign > 0 ? 127 : 0], to: x1Output) }  // right = positive
    }

    private func showBpmOnBothDigits() {
        lock.lock(); let m1 = lastTempoMag[1] ?? 0; let m2 = lastTempoMag[2] ?? 0; lock.unlock()
        sendDigit(1, m1)
        sendDigit(2, m2)
    }

    private func restoreBeatJumpOnBothDigits() {
        lock.lock(); let i1 = deckPosition[1] ?? 5; let i2 = deckPosition[2] ?? 5; lock.unlock()
        sendDigit(1, Self.beatJumpOrder[i1].cc)
        sendDigit(2, Self.beatJumpOrder[i2].cc)
    }

    /// Push couples loop ↔ beat jump: fire the absolute per-size auto-loop matching the current
    /// beat-jump size, or toggle the loop off if it's already active.
    private func handleLoopPush(deck: Int) {
        lock.lock()
        let active = loopActive[deck] ?? false
        let label = Self.beatJumpOrder[deckPosition[deck] ?? 5].label
        lock.unlock()
        if active {
            fireDjayNote(Self.autoLoopOnOffNote(deck))   // exit
            setLoopActive(deck, false)                    // optimistic (djay feedback confirms)
        } else if let note = Self.autoLoopSizeNote(deck: deck, size: label) {
            fireDjayNote(note)                            // start at beat-jump size
            setLoopActive(deck, true)                     // optimistic → instant flash
        } else {
            printError("KontrolX1: no auto-loop action for size \(label) (deck \(deck))")
        }
    }

    private func fireDjayNote(_ note: UInt8) {
        emitToDjay([0x90, note, 127])
        emitToDjay([0x90, note, 0])
    }

    private func isLoopActive(_ deck: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }; return loopActive[deck] ?? false
    }

    // MARK: - Loop blink (KA-270): while a loop is active, blink its digit between 0 and the length.

    private func startFlashTimer() {
        lock.lock(); defer { lock.unlock() }
        guard flashTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: flashQueue)
        t.schedule(deadline: .now() + Self.flashInterval, repeating: Self.flashInterval)
        t.setEventHandler { [weak self] in self?.flashTick() }
        t.resume()
        flashTimer = t
    }

    private func stopFlashTimer() {
        lock.lock(); defer { lock.unlock() }
        flashTimer?.cancel(); flashTimer = nil; flashOn = true
    }

    // 1-beat-jump button LEDs to railroad-flash while a loop is active (real note numbers from
    // the map — the Controller Editor's names were an octave low). Per deck two groups alternate;
    // each carries the button's normal + shift note so it flashes in either layer.
    // Deck 1: skipBackward1Beat G#0(20)/E4(64) ↔ skipForward1Beat A#0(22)/F#4(66).
    // Deck 2: A0(21)/F4(65) ↔ B0(23)/G4(67).
    private static let loopFlashLEDs: [Int: (a: [UInt8], b: [UInt8])] = [
        1: (a: [20], b: [22]),
        2: (a: [21], b: [23]),
    ]
    private static let loopFlashNotes: Set<UInt8> = [20, 21, 22, 23]

    /// Update loop on/off and drive the flash + digit. Called both optimistically on the push
    /// (so it feels instant) and on djay's confirming feedback; the `changed` guard makes the
    /// second call a no-op.
    private func setLoopActive(_ deck: Int, _ on: Bool) {
        lock.lock()
        let changed = (loopActive[deck] ?? false) != on
        loopActive[deck] = on
        let anyActive = loopActive.values.contains(true)
        let f = flashOn
        let idx = deckPosition[deck] ?? 5
        lock.unlock()
        guard changed else { return }
        if let x1Output { send([0x90, deck == 1 ? 26 : 27, on ? 127 : 0], to: x1Output) }  // X1 loop LED
        if on {
            startFlashTimer()
            if !syncModeActive() { sendFlashFrame(deck: deck, on: f) }  // sync shows the sign instead
        } else {
            turnOffLoopFlashLEDs(deck: deck)
            if !syncModeActive() { sendDigit(deck, Self.beatJumpOrder[idx].cc) }
            if !anyActive { stopFlashTimer() }
        }
    }

    private func sendFlashFrame(deck: Int, on: Bool) {
        guard let x1Output, let leds = Self.loopFlashLEDs[deck] else { return }
        for n in leds.a { send([0x90, n, on ? 127 : 0], to: x1Output) }   // railroad: A vs B
        for n in leds.b { send([0x90, n, on ? 0 : 127], to: x1Output) }
    }

    private func flashTick() {
        if syncModeActive() { return }  // sync-hold shows the tempo sign on the FX buttons instead
        lock.lock(); flashOn.toggle(); let on = flashOn; let active = loopActive; lock.unlock()
        for deck in [1, 2] where active[deck] == true { sendFlashFrame(deck: deck, on: on) }
    }

    private func turnOffLoopFlashLEDs(deck: Int) {
        guard let x1Output, let leds = Self.loopFlashLEDs[deck] else { return }
        for n in leds.a + leds.b { send([0x90, n, 0], to: x1Output) }
    }

    /// Snappy display: step the tracked beat-jump index on each detent and show it on CC 24/25
    /// immediately (the AX sync would lag ~8fps behind the encoder).
    private func predictBeatJumpDisplay(cc: UInt8, value: UInt8) {
        let direction = value == 0x01 ? 1 : (value == 0x7F ? -1 : 0)
        guard direction != 0 else { return }
        let deck = cc == 24 ? 1 : 2
        lock.lock()
        let next = min(max((deckPosition[deck] ?? 5) + direction, 0), Self.beatJumpOrder.count - 1)
        deckPosition[deck] = next
        lastRotaryTime[deck] = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        sendDigit(deck, Self.beatJumpOrder[next].cc)
    }

    /// djay → X1 hardware. Record state, forward LED feedback (except the bridge's display CCs).
    fileprivate func handleDjayOutput(_ bytes: [UInt8]) {
        guard bytes.count >= 3 else { return }
        let status = bytes[0] & 0xF0
        lock.lock()
        feedbackState[UInt16(bytes[0]) << 8 | UInt16(bytes[1])] = bytes[2]
        lock.unlock()
        // Track loop on/off from djay's autoLoopOnOff feedback (drives push start-vs-exit), and
        // reflect it on the X1's loop LED (which sits on the push note 26/27). Consume our own
        // state notes — they aren't real X1 controls.
        if status == 0x90 || status == 0x80, let deck = Self.deckForAutoLoopOnOffNote(bytes[1]) {
            setLoopActive(deck, status == 0x90 && bytes[2] > 0)  // confirms the optimistic push
            return
        }
        // While a loop is active the bridge owns the FX-flash LEDs — drop djay's feedback on
        // them so it doesn't fight the railroad blink.
        if status == 0x90 || status == 0x80, Self.loopFlashNotes.contains(bytes[1]) {
            lock.lock()
            let owned = loopActive.values.contains(true) || (syncHeld[1] ?? false) || (syncHeld[2] ?? false)
            lock.unlock()
            if owned { return }  // bridge owns these LEDs (railroad blink / tempo sign)
        }
        // Don't clobber the displays the bridge owns.
        if status == 0xB0, Self.ownedDisplayCCs.contains(bytes[1]) { return }
        if let x1Output { send(bytes, to: x1Output) }
    }

    // MARK: - Helpers

    private func emitToDjay(_ bytes: [UInt8]) {
        var pl = MIDIPacketList()
        var pkt = MIDIPacketListInit(&pl)
        pkt = MIDIPacketListAdd(&pl, MemoryLayout<MIDIPacketList>.size, pkt, 0, bytes.count, bytes)
        MIDIReceived(virtualSource, &pl)
    }

    private func send(_ bytes: [UInt8], to endpoint: MIDIEndpointRef) {
        var pl = MIDIPacketList()
        var pkt = MIDIPacketListInit(&pl)
        pkt = MIDIPacketListAdd(&pl, MemoryLayout<MIDIPacketList>.size, pkt, 0, bytes.count, bytes)
        MIDISend(x1OutPort, endpoint, &pl)
    }

    /// Drive a deck's display digit on both the main CC (24/25) and the shift-display CC (68/69),
    /// so the shift layer always mirrors the main one.
    private func sendDigit(_ deck: Int, _ value: UInt8) {
        guard let x1Output else { return }
        send([0xB0, deck == 1 ? 24 : 25, value], to: x1Output)
        send([0xB0, deck == 1 ? 68 : 69, value], to: x1Output)
    }

    private static func indexForLabel(_ value: String) -> Int? {
        let num = String(value.split(separator: " ").first ?? "")
        return beatJumpOrder.firstIndex { $0.label == num }
    }

    private static func ccForLabel(_ value: String) -> UInt8? {
        guard let idx = indexForLabel(value) else { return nil }
        return beatJumpOrder[idx].cc
    }
}

private func endpointName(_ ep: MIDIEndpointRef) -> String {
    var name: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(ep, kMIDIPropertyName, &name)
    return (name?.takeRetainedValue() as String?) ?? ""
}

private func packetBytes(_ packet: MIDIPacket) -> [UInt8] {
    Array(Mirror(reflecting: packet.data).children.prefix(Int(packet.length)).map { $0.value as! UInt8 })
}

// MARK: - C callbacks

private func x1InputCallback(packetList: UnsafePointer<MIDIPacketList>, refCon: UnsafeMutableRawPointer?, connRefCon: UnsafeMutableRawPointer?) {
    let controller = Unmanaged<KontrolX1>.fromOpaque(refCon!).takeUnretainedValue()
    var packet = packetList.pointee.packet
    for _ in 0..<packetList.pointee.numPackets {
        if packet.length >= 1 { controller.handleX1Input(packetBytes(packet)) }
        packet = MIDIPacketNext(&packet).pointee
    }
}

private func djayOutputCallback(packetList: UnsafePointer<MIDIPacketList>, refCon: UnsafeMutableRawPointer?, srcConnRefCon: UnsafeMutableRawPointer?) {
    let controller = Unmanaged<KontrolX1>.fromOpaque(refCon!).takeUnretainedValue()
    var packet = packetList.pointee.packet
    for _ in 0..<packetList.pointee.numPackets {
        if packet.length >= 1 { controller.handleDjayOutput(packetBytes(packet)) }
        packet = MIDIPacketNext(&packet).pointee
    }
}
