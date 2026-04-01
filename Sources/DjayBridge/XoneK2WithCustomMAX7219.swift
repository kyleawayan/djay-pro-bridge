import CoreMIDI
import Foundation

/// Handles XONE:K2 MIDI input for beat jump, loop, modifier, and drives a MAX7219
/// 8-digit 7-segment serial display. AX tree values sync tracked positions.
public class XoneK2WithCustomMAX7219 {
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()

    private static let k2DeviceName = "XONE:K2"

    // MARK: - Callbacks

    public var onBeatJumpChanged: ((Int, String) -> Void)?
    public var onLoopChanged: ((Int, String) -> Void)?
    public var onLoopToggled: ((Int, Bool) -> Void)?
    public var onModifierChanged: ((Bool) -> Void)?

    // MARK: - Value orders

    private static let beatJumpOrder: [String] = [
        "1/32", "1/16", "1/8", "1/4", "1/2",
        "1", "2", "4", "8", "16", "32", "64", "128",
    ]

    private static let loopOrder: [String] = [
        "1/32", "1/16", "1/8", "1/4", "1/2",
        "1", "2", "4", "8", "16", "32", "64", "128",
    ]

    // MARK: - State

    private let lock = NSLock()
    private var beatJumpPosition: [Int: Int] = [1: 5, 2: 5]  // default "1"
    private var loopPosition: [Int: Int] = [1: 7, 2: 7]      // default "4"
    private var loopOn: [Int: Bool] = [1: false, 2: false]
    public private(set) var isModifierHeld = false

    private var beatJumpAccum: [Int: Int] = [:]
    private var loopAccum: [Int: Int] = [:]

    private var lastBeatJumpRotaryTime: [Int: CFAbsoluteTime] = [:]
    private var lastLoopRotaryTime: [Int: CFAbsoluteTime] = [:]
    private var lastLoopToggleTime: [Int: CFAbsoluteTime] = [:]
    private static let rotaryCooldown: CFAbsoluteTime = 0.5

    // MARK: - Init

    public init() {
        var status = MIDIClientCreate("XoneK2" as CFString, nil, nil, &client)
        guard status == noErr else {
            printError("XoneK2: MIDIClientCreate failed (\(status))")
            return
        }

        status = MIDIInputPortCreate(client, "K2Input" as CFString, k2MidiReadCallback,
                                     Unmanaged.passUnretained(self).toOpaque(), &inputPort)
        guard status == noErr else {
            printError("XoneK2: MIDIInputPortCreate failed (\(status))")
            return
        }

        let srcCount = MIDIGetNumberOfSources()
        for i in 0..<srcCount {
            let endpoint = MIDIGetSource(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &name)
            if let n = name?.takeRetainedValue() as String?, n == Self.k2DeviceName {
                MIDIPortConnectSource(inputPort, endpoint, nil)
                printError("XoneK2: listening on \(n)")
            }
        }
    }

    deinit { MIDIClientDispose(client) }

    // MARK: - AX sync

    /// Sync beat jump position from AX tree (respects rotary cooldown).
    public func syncBeatJump(deck: Int, value: String) {
        lock.lock()
        let lastSpin = lastBeatJumpRotaryTime[deck] ?? 0
        lock.unlock()
        guard (CFAbsoluteTimeGetCurrent() - lastSpin) >= Self.rotaryCooldown else { return }

        let label = String(value.split(separator: " ").first ?? "")
        guard let idx = Self.beatJumpOrder.firstIndex(of: label) else { return }
        lock.lock()
        let changed = beatJumpPosition[deck] != idx
        beatJumpPosition[deck] = idx
        lock.unlock()
        if changed { onBeatJumpChanged?(deck, label) }
    }

    /// Sync loop size from AX tree (respects rotary cooldown).
    public func syncLoop(deck: Int, value: String) {
        lock.lock()
        let lastSpin = lastLoopRotaryTime[deck] ?? 0
        lock.unlock()
        guard (CFAbsoluteTimeGetCurrent() - lastSpin) >= Self.rotaryCooldown else { return }

        let label = String(value.split(separator: " ").first ?? "")
        guard let idx = Self.loopOrder.firstIndex(of: label) else { return }
        lock.lock()
        let changed = loopPosition[deck] != idx
        loopPosition[deck] = idx
        lock.unlock()
        if changed { onLoopChanged?(deck, label) }
    }

    /// Sync loop active state from AX tree (respects toggle cooldown).
    public func syncLoopActive(deck: Int, isActive: Bool) {
        lock.lock()
        let lastToggle = lastLoopToggleTime[deck] ?? 0
        let cooldownActive = (CFAbsoluteTimeGetCurrent() - lastToggle) < Self.rotaryCooldown
        guard !cooldownActive else { lock.unlock(); return }
        let changed = loopOn[deck] != isActive
        loopOn[deck] = isActive
        lock.unlock()
        if changed { onLoopToggled?(deck, isActive) }
    }

    // MARK: - MIDI handlers

    fileprivate func handleBeatJumpRotary(deck: Int, direction: Int) {
        guard !isModifierHeld else { return }
        guard let label = stepPosition(
            position: &beatJumpPosition, accum: &beatJumpAccum,
            order: Self.beatJumpOrder, deck: deck, direction: direction,
            lastTime: &lastBeatJumpRotaryTime
        ) else { return }
        onBeatJumpChanged?(deck, label)
        printError("XoneK2: beat jump deck \(deck) → \(label)")
    }

    fileprivate func handleLoopRotary(deck: Int, direction: Int) {
        guard !isModifierHeld else { return }
        guard let label = stepPosition(
            position: &loopPosition, accum: &loopAccum,
            order: Self.loopOrder, deck: deck, direction: direction,
            lastTime: &lastLoopRotaryTime
        ) else { return }
        onLoopChanged?(deck, label)
        printError("XoneK2: loop deck \(deck) → \(label)")
    }

    fileprivate func handleLoopToggle(deck: Int, velocity: UInt8) {
        guard velocity > 0 else { return }
        lock.lock()
        let newState = !(loopOn[deck] ?? false)
        loopOn[deck] = newState
        lastLoopToggleTime[deck] = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        onLoopToggled?(deck, newState)
        printError("XoneK2: loop deck \(deck) → \(newState ? "ON" : "OFF")")
    }

    fileprivate func handleModifier(pressed: Bool) {
        isModifierHeld = pressed
        onModifierChanged?(pressed)
    }

    // MARK: - Helpers

    private func stepPosition(
        position: inout [Int: Int], accum: inout [Int: Int],
        order: [String], deck: Int, direction: Int,
        lastTime: inout [Int: CFAbsoluteTime]
    ) -> String? {
        lock.lock()
        var a = accum[deck] ?? 0
        a += direction
        if (a > 0 && direction < 0) || (a < 0 && direction > 0) { a = direction }
        if abs(a) < 1 {
            accum[deck] = a
            lock.unlock()
            return nil
        }
        let step = a > 0 ? 1 : -1
        accum[deck] = 0
        let current = position[deck] ?? 5
        let next = min(max(current + step, 0), order.count - 1)
        position[deck] = next
        lastTime[deck] = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        return order[next]
    }
}

// MARK: - MIDI callback

private func k2MidiReadCallback(packetList: UnsafePointer<MIDIPacketList>, refCon: UnsafeMutableRawPointer?, connRefCon: UnsafeMutableRawPointer?) {
    let k2 = Unmanaged<XoneK2WithCustomMAX7219>.fromOpaque(refCon!).takeUnretainedValue()
    var packet = packetList.pointee.packet
    for _ in 0..<packetList.pointee.numPackets {
        let bytes = Mirror(reflecting: packet.data).children.map { $0.value as! UInt8 }
        guard packet.length >= 3 else {
            packet = MIDIPacketNext(&packet).pointee
            continue
        }
        let status = bytes[0]
        let note = bytes[1]
        let val = bytes[2]

        let direction: Int = (val >= 1 && val <= 63) ? 1 : (val >= 65 ? -1 : 0)

        // CC on channel 14 (0xBE)
        if status == 0xBE {
            if (note == 0 || note == 3) && direction != 0 {
                k2.handleBeatJumpRotary(deck: note == 0 ? 1 : 2, direction: direction)
            }
            if (note == 1 || note == 2) && direction != 0 {
                k2.handleLoopRotary(deck: note == 1 ? 1 : 2, direction: direction)
            }
        }
        // Note On channel 14 (0x9E)
        if status == 0x9E {
            if note == 53 || note == 54 {
                k2.handleLoopToggle(deck: note == 53 ? 1 : 2, velocity: val)
            }
            if note == 12 || note == 15 {
                k2.handleModifier(pressed: val > 0)
            }
        }
        // Note Off channel 14 (0x8E)
        if status == 0x8E {
            if note == 12 || note == 15 {
                k2.handleModifier(pressed: false)
            }
        }

        packet = MIDIPacketNext(&packet).pointee
    }
}
