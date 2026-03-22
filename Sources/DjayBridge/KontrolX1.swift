import CoreMIDI
import Foundation

public class KontrolX1 {
    private var client = MIDIClientRef()
    private var outputPort = MIDIPortRef()
    private var inputPort = MIDIPortRef()
    private var destination: MIDIEndpointRef?

    private static let outputDeviceName = "Traktor Kontrol X1 MK2 - 1 Output"
    private static let inputDeviceName = "Traktor Kontrol X1 MK2 - 1 Input"

    // Ordered beat jump values: 1/32 → 127
    private static let beatJumpOrder: [(label: String, cc: UInt8)] = [
        ("1/32", 0), ("1/16", 116), ("1/8", 118), ("1/4", 114), ("1/2", 112),
        ("1", 1), ("2", 2), ("4", 4), ("8", 8), ("16", 16), ("32", 32), ("64", 64), ("128", 127),
    ]

    // Current position in beatJumpOrder per deck (index into the array)
    private let lock = NSLock()
    private var deckPosition: [Int: Int] = [1: 5, 2: 5]  // default to "1 Beat"
    private var lastRotaryTime: [Int: CFAbsoluteTime] = [:]
    private static let rotaryCooldown: CFAbsoluteTime = 0.5  // ignore AX corrections for 500ms after last spin

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
            if let n = name?.takeRetainedValue() as String?, n == Self.inputDeviceName {
                MIDIPortConnectSource(inputPort, endpoint, nil)
                printError("KontrolX1: listening on \(Self.inputDeviceName)")
                break
            }
        }
    }

    deinit {
        MIDIClientDispose(client)
    }

    /// Called by AX poll to sync position to reality.
    public func sendBeatJump(deck: Int, value: String) {
        guard let destination else { return }

        lock.lock()
        let lastSpin = lastRotaryTime[deck] ?? 0
        lock.unlock()

        let now = CFAbsoluteTimeGetCurrent()
        let cooldownActive = (now - lastSpin) < Self.rotaryCooldown

        // Sync our tracked position to what AX reports (only if not mid-spin)
        if !cooldownActive, let idx = Self.indexForLabel(value) {
            lock.lock()
            deckPosition[deck] = idx
            lock.unlock()
        }

        let cc: UInt8 = deck == 1 ? 24 : 25
        guard let ccValue = Self.ccForLabel(value) else {
            printError("KontrolX1: unknown beat jump value: \(value)")
            return
        }

        if !cooldownActive {
            sendCC(channel: 0, cc: cc, value: ccValue, to: destination)
        }
    }

    /// Called from MIDI input when rotary encoder turns.
    fileprivate func handleRotary(cc: UInt8, direction: Int) {
        guard let destination else { return }

        // CC24 = deck 1, CC25 = deck 2
        let deck: Int
        switch cc {
        case 24: deck = 1
        case 25: deck = 2
        default: return
        }

        lock.lock()
        let current = deckPosition[deck] ?? 5
        let next = min(max(current + direction, 0), Self.beatJumpOrder.count - 1)
        deckPosition[deck] = next
        lastRotaryTime[deck] = CFAbsoluteTimeGetCurrent()
        lock.unlock()

        let entry = Self.beatJumpOrder[next]
        sendCC(channel: 0, cc: cc, value: entry.cc, to: destination)
        printError("KontrolX1: rotary deck \(deck) → \(entry.label) (predicted)")
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
            // CC message on channel 0
            if status == 0xB0, (cc == 24 || cc == 25) {
                let direction = val == 0x01 ? 1 : (val == 0x7F ? -1 : 0)
                if direction != 0 {
                    controller.handleRotary(cc: cc, direction: direction)
                }
            }
        }
        packet = MIDIPacketNext(&packet).pointee
    }
}
