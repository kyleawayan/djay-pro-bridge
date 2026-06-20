import CoreMIDI
import Foundation

/// Reads the Traktor Kontrol Z1 mixer faders directly over MIDI — deck line volumes and the
/// crossfader — so on-air / main-deck detection doesn't depend on djay's Accessibility view,
/// which hides line volume in some layouts. Listens in parallel with djay; read-only, nothing is
/// sent to the Z1.
public class KontrolZ1 {
    private let lock = NSLock()
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var deck1Vol: Int?
    private var deck2Vol: Int?
    private var crossfader: Int?

    // Z1 native MIDI: line volume = CC 6 (deck 1 = ch 1, deck 2 = ch 2); crossfader = CC 5.
    private static let volCC: UInt8 = 6
    private static let crossfaderCC: UInt8 = 5

    public init() {
        MIDIClientCreate("DjayBridge-Z1" as CFString, nil, nil, &client)
        MIDIInputPortCreateWithBlock(client, "Z1 in" as CFString, &inPort) { [weak self] listPtr, _ in
            self?.handle(listPtr)
        }
        connectSources()
    }

    private func connectSources() {
        var connected = false
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(src, kMIDIPropertyName, &name)
            if let n = name?.takeRetainedValue() as String?, n.contains("Z1") {
                MIDIPortConnectSource(inPort, src, nil)
                connected = true
                printError("KontrolZ1: listening to '\(n)'")
            }
        }
        if !connected {
            printError("KontrolZ1: no 'Z1' MIDI source found — faders won't update")
        }
    }

    private func handle(_ listPtr: UnsafePointer<MIDIPacketList>) {
        var packet = listPtr.pointee.packet
        for _ in 0..<listPtr.pointee.numPackets {
            let length = Int(packet.length)
            withUnsafeBytes(of: packet.data) { raw in
                var i = 0
                while i + 2 < length {
                    let status = raw[i]
                    if status & 0xF0 == 0xB0 {  // Control Change
                        record(channel: status & 0x0F, cc: raw[i + 1], value: Int(raw[i + 2]))
                        i += 3
                    } else if status & 0x80 != 0 {
                        i += 3
                    } else {
                        i += 1
                    }
                }
            }
            packet = withUnsafePointer(to: &packet) { MIDIPacketNext($0).pointee }
        }
    }

    private func record(channel: UInt8, cc: UInt8, value: Int) {
        lock.lock(); defer { lock.unlock() }
        switch (cc, channel) {
        case (Self.volCC, 0): deck1Vol = value           // CC 6, ch 1
        case (Self.volCC, 1): deck2Vol = value           // CC 6, ch 2
        case (Self.crossfaderCC, _): crossfader = value  // CC 5 (only one crossfader)
        default: break
        }
    }

    private static func percent(_ v: Int?) -> String? {
        guard let v else { return nil }
        return "\(Int((Double(v) / 127.0 * 100).rounded()))%"
    }

    /// Line volume as a percent string ("0%"–"100%"), or nil until the fader is first moved.
    public func deckVolumePercent(_ deck: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return Self.percent(deck == 1 ? deck1Vol : deck2Vol)
    }

    /// Crossfader position as a percent string (0% = full left / deck 1, 100% = full right /
    /// deck 2), or nil until it's first moved.
    public func crossfaderPercent() -> String? {
        lock.lock(); defer { lock.unlock() }
        return Self.percent(crossfader)
    }
}
