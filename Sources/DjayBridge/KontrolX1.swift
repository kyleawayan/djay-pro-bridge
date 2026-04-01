import CoreMIDI
import Foundation

public class KontrolX1 {
    private var client = MIDIClientRef()
    private var outputPort = MIDIPortRef()
    private var inputPort = MIDIPortRef()
    private var destination: MIDIEndpointRef?

    private static let outputDeviceName = "Traktor Kontrol X1 MK2 - 1 Output"
    private static let inputDeviceName = "Traktor Kontrol X1 MK2 - 1 Input"
    private static let k2InputDeviceName = "XONE:K2"

    /// Fired when beat jump changes from rotary input: (deck, label)
    public var onBeatJumpChanged: ((Int, String) -> Void)?

    // Ordered beat jump values: 1/32 → 127
    private static let beatJumpOrder: [(label: String, cc: UInt8)] = [
        ("1/32", 0), ("1/16", 116), ("1/8", 118), ("1/4", 114), ("1/2", 112),
        ("1", 1), ("2", 2), ("4", 4), ("8", 8), ("16", 16), ("32", 32), ("64", 64), ("128", 127),
    ]

    // Current position in beatJumpOrder per deck (index into the array)
    private let lock = NSLock()
    private var deckPosition: [Int: Int] = [1: 5, 2: 5]  // default to "1 Beat"
    private var rotaryAccum: [Int: Int] = [:]  // accumulated clicks per deck
    private static let clicksPerStep = 2
    private var lastRotaryTime: [Int: CFAbsoluteTime] = [:]
    private var crossfaderPosition: UInt8 = 64  // 0-127, default to center
    private var lastCrossfaderTime: CFAbsoluteTime = 0
    private var crossfaderBlinkOn = false
    private var crossfaderBlinkTimer: DispatchSourceTimer?
    private static let rotaryCooldown: CFAbsoluteTime = 0.5  // ignore AX corrections for 500ms after last spin
    private static let blinkInterval: TimeInterval = 0.3

    public init() {
        var status = MIDIClientCreate("DjayBridge" as CFString, nil, nil, &client)
        guard status == noErr else {
            printError("KontrolX1: MIDIClientCreate failed (\(status))")
            return
        }

        status = MIDIOutputPortCreate(client, "Output" as CFString, &outputPort)
        guard status == noErr else {
            printError("KontrolX1: MIDIOutputPortCreate failed (\(status))")
            return
        }

        // Find output destination
        let destCount = MIDIGetNumberOfDestinations()
        for i in 0..<destCount {
            let endpoint = MIDIGetDestination(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &name)
            if let n = name?.takeRetainedValue() as String?, n == Self.outputDeviceName {
                destination = endpoint
                printError("KontrolX1: found output \(Self.outputDeviceName)")
                break
            }
        }
        if destination == nil {
            printError("KontrolX1: \(Self.outputDeviceName) not found among \(destCount) destinations")
        }

        // Set up MIDI input to listen for rotary encoder
        status = MIDIInputPortCreate(client, "Input" as CFString, midiReadCallback, Unmanaged.passUnretained(self).toOpaque(), &inputPort)
        guard status == noErr else {
            printError("KontrolX1: MIDIInputPortCreate failed (\(status))")
            return
        }

        let srcCount = MIDIGetNumberOfSources()
        for i in 0..<srcCount {
            let endpoint = MIDIGetSource(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &name)
            if let n = name?.takeRetainedValue() as String? {
                if n == Self.inputDeviceName {
                    MIDIPortConnectSource(inputPort, endpoint, nil)
                    printError("KontrolX1: listening on \(n)")
                } else if n == Self.k2InputDeviceName {
                    MIDIPortConnectSource(inputPort, endpoint, nil)
                    printError("KontrolX1: listening on \(n)")
                }
            }
        }
    }

    deinit {
        MIDIClientDispose(client)
    }

    /// Called by AX poll to sync position to reality.
    public func sendBeatJump(deck: Int, value: String) {
        lock.lock()
        let lastSpin = lastRotaryTime[deck] ?? 0
        lock.unlock()

        let now = CFAbsoluteTimeGetCurrent()
        let cooldownActive = (now - lastSpin) < Self.rotaryCooldown

        // Sync our tracked position to what AX reports (only if not mid-spin)
        if !cooldownActive, let idx = Self.indexForLabel(value) {
            lock.lock()
            let changed = deckPosition[deck] != idx
            deckPosition[deck] = idx
            lock.unlock()
            if changed {
                let label = Self.beatJumpOrder[idx].label
                onBeatJumpChanged?(deck, label)
            }
        }

        // Send to X1 if connected
        guard let destination else { return }
        let cc: UInt8 = deck == 1 ? 24 : 25
        guard let ccValue = Self.ccForLabel(value) else {
            printError("KontrolX1: unknown beat jump value: \(value)")
            return
        }

        if !cooldownActive {
            sendCC(channel: 0, cc: cc, value: ccValue, to: destination)
        }
    }

    /// Called by AX poll to sync crossfader position as CC 29 (0-127).
    public func sendCrossfader(value: String) {
        guard destination != nil else { return }
        guard let pct = Int(value.replacingOccurrences(of: "%", with: "")) else {
            printError("KontrolX1: unknown crossfader value: \(value)")
            return
        }
        let ccValue = UInt8(min(max(pct * 127 / 100, 0), 127))

        lock.lock()
        let cooldownActive = (CFAbsoluteTimeGetCurrent() - lastCrossfaderTime) < Self.rotaryCooldown
        if !cooldownActive {
            crossfaderPosition = ccValue
        }
        lock.unlock()

        if !cooldownActive {
            updateCrossfaderBlink(value: ccValue)
        }
    }

    /// Called from MIDI input when rotary encoder turns.
    fileprivate func handleRotary(deck: Int, direction: Int) {
        lock.lock()
        var accum = rotaryAccum[deck] ?? 0
        accum += direction
        // Direction change resets accumulator
        if (accum > 0 && direction < 0) || (accum < 0 && direction > 0) {
            accum = direction
        }
        if abs(accum) < Self.clicksPerStep {
            rotaryAccum[deck] = accum
            lock.unlock()
            return
        }
        // Consumed enough clicks for a step
        let step = accum > 0 ? 1 : -1
        rotaryAccum[deck] = 0
        let current = deckPosition[deck] ?? 5
        let next = min(max(current + step, 0), Self.beatJumpOrder.count - 1)
        deckPosition[deck] = next
        lastRotaryTime[deck] = CFAbsoluteTimeGetCurrent()
        lock.unlock()

        let entry = Self.beatJumpOrder[next]

        // Send to X1 if connected
        if let destination {
            let cc: UInt8 = deck == 1 ? 24 : 25
            sendCC(channel: 0, cc: cc, value: entry.cc, to: destination)
        }

        onBeatJumpChanged?(deck, entry.label)
        printError("KontrolX1: rotary deck \(deck) → \(entry.label) (predicted)")
    }

    /// Called from MIDI input when crossfader moves (absolute 0-127).
    fileprivate func handleCrossfader(value: UInt8) {
        guard destination != nil else { return }

        lock.lock()
        crossfaderPosition = value
        lastCrossfaderTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()

        updateCrossfaderBlink(value: value)
        printError("KontrolX1: crossfader → \(value)")
    }

    private func updateCrossfaderBlink(value: UInt8) {
        guard let destination else { return }

        if value == 0 || value == 127 {
            // At extremes: stop blinking, send steady value
            crossfaderBlinkTimer?.cancel()
            crossfaderBlinkTimer = nil
            sendCC(channel: 0, cc: 29, value: value, to: destination)
        } else {
            // Not at extreme: start blink if not already running
            sendCC(channel: 0, cc: 29, value: value, to: destination)
            crossfaderBlinkOn = true

            if crossfaderBlinkTimer == nil {
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "cf-blink"))
                timer.schedule(deadline: .now() + Self.blinkInterval, repeating: Self.blinkInterval)
                timer.setEventHandler { [weak self] in
                    guard let self, let destination = self.destination else { return }
                    self.lock.lock()
                    self.crossfaderBlinkOn.toggle()
                    let pos = self.crossfaderPosition
                    let on = self.crossfaderBlinkOn
                    self.lock.unlock()
                    self.sendCC(channel: 0, cc: 29, value: on ? pos : 64, to: destination)
                }
                timer.resume()
                crossfaderBlinkTimer = timer
            }
        }
    }

    // MARK: - Helpers

    private static func indexForLabel(_ value: String) -> Int? {
        let num = String(value.split(separator: " ").first ?? "")
        return beatJumpOrder.firstIndex { $0.label == num }
    }

    private static func ccForLabel(_ value: String) -> UInt8? {
        guard let idx = indexForLabel(value) else { return nil }
        return beatJumpOrder[idx].cc
    }

    private func sendCC(channel: UInt8, cc: UInt8, value: UInt8, to endpoint: MIDIEndpointRef) {
        let status: UInt8 = 0xB0 | (channel & 0x0F)
        var packetList = MIDIPacketList()
        var packet = MIDIPacketListInit(&packetList)
        let bytes: [UInt8] = [status, cc, value]
        packet = MIDIPacketListAdd(&packetList, MemoryLayout<MIDIPacketList>.size, packet, 0, 3, bytes)
        MIDISend(outputPort, endpoint, &packetList)
    }
}

// MARK: - MIDI input callback (C function pointer)

private func midiReadCallback(packetList: UnsafePointer<MIDIPacketList>, refCon: UnsafeMutableRawPointer?, connRefCon: UnsafeMutableRawPointer?) {
    let controller = Unmanaged<KontrolX1>.fromOpaque(refCon!).takeUnretainedValue()
    var packet = packetList.pointee.packet
    for _ in 0..<packetList.pointee.numPackets {
        let bytes = Mirror(reflecting: packet.data).children.map { $0.value as! UInt8 }
        if packet.length >= 3 {
            let status = bytes[0]
            let cc = bytes[1]
            let val = bytes[2]

            // Decode relative rotary: 1-63 = CW, 65-127 = CCW
            let direction: Int = (val >= 1 && val <= 63) ? 1 : (val >= 65 ? -1 : 0)

            // X1: CC on channel 0
            if status == 0xB0 {
                if cc == 24 || cc == 25 {
                    if direction != 0 {
                        let deck = cc == 24 ? 1 : 2
                        controller.handleRotary(deck: deck, direction: direction)
                    }
                } else if cc == 29 {
                    controller.handleCrossfader(value: val)
                }
            }
            // K2: CC on channel 14 (0xBE)
            if status == 0xBE {
                if (cc == 0 || cc == 3) && direction != 0 {
                    let deck = cc == 0 ? 1 : 2
                    controller.handleRotary(deck: deck, direction: direction)
                }
            }
        }
        packet = MIDIPacketNext(&packet).pointee
    }
}
