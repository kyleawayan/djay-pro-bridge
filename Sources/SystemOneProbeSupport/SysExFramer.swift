import Foundation

public struct SysExFramer {
    public enum Event: Equatable {
        case message([UInt8])
        case interrupted(Int)
        case oversized(Int)
    }

    let maximumMessageBytes: Int
    public private(set) var partial: [UInt8] = []

    public init(maximumMessageBytes: Int = 1_048_576) {
        precondition(maximumMessageBytes >= 2)
        self.maximumMessageBytes = maximumMessageBytes
    }

    public mutating func consume(_ bytes: Data) -> [Event] {
        var events: [Event] = []
        for byte in bytes {
            // Realtime messages may be interleaved without ending a SysEx message.
            if byte >= 0xf8 { continue }
            if byte == 0xf0 {
                if !partial.isEmpty { events.append(.interrupted(partial.count)) }
                partial = [byte]
                continue
            }
            guard !partial.isEmpty else { continue }
            if byte >= 0x80 && byte != 0xf7 {
                events.append(.interrupted(partial.count))
                partial.removeAll(keepingCapacity: true)
                continue
            }
            partial.append(byte)
            if partial.count > maximumMessageBytes {
                events.append(.oversized(partial.count))
                partial.removeAll(keepingCapacity: true)
            } else if byte == 0xf7 {
                events.append(.message(partial))
                partial.removeAll(keepingCapacity: true)
            }
        }
        return events
    }
}
