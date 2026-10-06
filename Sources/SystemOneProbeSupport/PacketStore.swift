import Foundation

public enum PacketScope: Hashable, Sendable, Comparable {
    case global
    case deck(UInt32)

    public var title: String {
        switch self {
        case .global: return "Global"
        case .deck(let index): return "Deck \(UInt64(index) + 1) · index \(index)"
        }
    }
    public static func < (lhs: PacketScope, rhs: PacketScope) -> Bool {
        switch (lhs, rhs) {
        case (.global, .deck): return true
        case (.deck(let a), .deck(let b)): return a < b
        default: return false
        }
    }
}

public struct PacketSnapshot: Sendable {
    public let raw: [UInt8]
    public let decodedFrame: [UInt8]
    public let packet: DebugPacket
    public let changed: [Date]
    public let payloadChanged: [Date]
    public let received: Date
    public let elapsed: Double
    public var count: Int
    public let assembly: String
}

public struct PacketStore: Sendable {
    public private(set) var latest: [PacketScope: [UInt64: PacketSnapshot]] = [:]
    public private(set) var images: [UInt32: PacketSnapshot] = [:]
    public init() {}

    public mutating func record(raw: [UInt8], decodedFrame: [UInt8], packet: DebugPacket,
                                elapsed: Double, assembly: String, received: Date = Date()) {
        let scope = packet.deckIndex.map(PacketScope.deck) ?? .global
        let key = packet.field ?? UInt64.max
        let previousFamily = latest[scope]?[key]
        let previous: PacketSnapshot?
        if let index = packet.cacheIndex { previous = images[index] }
        else { previous = previousFamily }
        let entries = latest.values.reduce(0) { $0 + $1.count }
        guard entries < 512 || previousFamily != nil else { return }
        func changes(_ bytes: [UInt8], old: [UInt8], times: [Date]) -> [Date] {
            bytes.enumerated().map { index, byte in
                index < old.count && index < times.count && old[index] == byte ? times[index] : received
            }
        }
        var snapshot = PacketSnapshot(raw: raw, decodedFrame: decodedFrame, packet: packet,
            changed: changes(raw, old: previous?.raw ?? [], times: previous?.changed ?? []),
            payloadChanged: changes(packet.payload, old: previous?.packet.payload ?? [], times: previous?.payloadChanged ?? []),
            received: received, elapsed: elapsed, count: (previous?.count ?? 0) + 1, assembly: assembly)
        if let index = packet.cacheIndex, images.count < 128 || images[index] != nil { images[index] = snapshot }
        snapshot.count = (previousFamily?.count ?? 0) + 1
        latest[scope, default: [:]][key] = snapshot
    }
}
