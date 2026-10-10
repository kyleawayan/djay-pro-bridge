import Foundation

public struct LibraryRow: Identifiable, Sendable {
    public let id: UInt32
    public var title: String
    public var artist: String
    public var tempo: Double?
    public var key: String
    public var duration: Double?
    public var artwork: Data? = nil
    public var artIndex: UInt32?
    public var kind: String
    public var packet: DebugPacket
}

public struct DeckLoopRegion: Sendable {
    public let start: Double
    public let end: Double
    public let status: UInt64
}

public struct DeckOverview: Sendable {
    public var title = ""
    public var artist = ""
    public var duration: Double?
    public var position: Double?
    public var velocity: Double?
    public var tempo: Double?
    public var key = ""
    public var loaded = false
    public var artwork: Data? = nil
    public var artIndex: UInt32?
    public var overview: Data?
    public var detailChunks: [UInt64: [UInt8]] = [:]
    public var beatAnchors = 0
    public var beatGrid: [WaveformBeatAnchor] = []
    public var sampleRate: Double?
    public var lengthInSamples: UInt64?
    public var trackStart = 0.0
    public var cues: Set<UInt32> = []
    public var loops: Set<Int32> = []
    public var loopRegions: [Int32: DeckLoopRegion] = [:]
    public var beatJumpLabel = ""
    public var speedRange = ""
    public var keyLock = false
    public var cuePackets: [UInt32: DebugPacket] = [:]
    public var loopPackets: [Int32: DebugPacket] = [:]
    public var loopLabel = ""
    public var loopEnabled = false
    public var lastUpdate: Date?
    public init() {}
    public var elapsed: Double? {
        guard let duration, let position else { return nil }
        return duration * position
    }
    public var detailSampleCount: Int { detailChunks.values.reduce(0) { $0 + $1.count / 4 } }
}

public struct OverviewState: Sendable {
    private var imageCache: [UInt32: Data] = [:]
    public private(set) var decks: [UInt32: DeckOverview] = [:]
    public private(set) var libraryTitle = ""
    public private(set) var libraryRows: [UInt32: LibraryRow] = [:]
    public private(set) var libraryRowCount: UInt64?
    public private(set) var selectedLibraryRow: UInt32?
    public private(set) var appVersion: String?
    public init() {}

    public mutating func consume(_ packet: DebugPacket, received: Date = Date()) {
        guard let family = packet.field, let body = Body(packet) else { return }
        if family == 90, let index = packet.cacheIndex, let image = packet.image {
            if imageCache[index] != nil || imageCache.count < 128 { imageCache[index] = image }
            return
        }
        func named(_ name: String, depth: Int = 0) -> String {
            packet.fields.first { $0.depth == depth && $0.name.hasSuffix(": " + name) }?.value.components(separatedBy: " (").first ?? ""
        }
        if let index = packet.deckIndex {
            var deck = decks[index] ?? DeckOverview()
            switch family {
            case 50:
                deck.title = body.text(2); deck.artist = body.text(3)
                deck.sampleRate = body.number(4)
                deck.lengthInSamples = body.uint(5, default: 0)
                deck.duration = nil
                if let sampleRate = deck.sampleRate, let samples = deck.lengthInSamples, sampleRate > 0 {
                    deck.duration = Double(samples) / sampleRate
                }
            case 51:
                deck.position = body.number(2) ?? 0; deck.velocity = body.number(3) ?? 0
            case 52: deck.tempo = body.number(2)
            case 53: deck.key = named("key")
            case 54: deck.keyLock = body.uint(2, default: 0) != 0
            case 55: deck = DeckOverview()
            case 56:
                deck.artIndex = body.index(2)
                deck.artwork = imageCache[body.index(2)]
            case 58: deck.speedRange = body.text(2)
            case 61: deck.beatJumpLabel = body.text(2)
            case 59: deck.loopLabel = body.text(2)
            case 60: deck.loopEnabled = body.uint(2, default: 0) != 0
            case 62:
                if let samples = packet.waveform, let offset = packet.waveformOffset {
                    let oldSize = deck.detailChunks[offset]?.count ?? 0
                    let size = deck.detailChunks.values.reduce(0) { $0 + $1.count } - oldSize + samples.count
                    if size <= 4 * 1_048_576 && (deck.detailChunks.count < 512 || oldSize > 0) { deck.detailChunks[offset] = samples }
                }
            case 63:
                deck.trackStart = body.number(3) ?? (body.value(3) == nil ? 0 : .nan)
                deck.beatGrid = body.values.compactMap { field, value in
                    guard field == 2, case .bytes(let bytes) = value, let anchor = Body(bytes) else { return nil }
                    guard let position = anchor.number(1) ?? (anchor.value(1) == nil ? 0 : nil) else { return nil }
                    return WaveformBeatAnchor(positionInSamples: position,
                                              positionInBeats: Int32(truncatingIfNeeded: anchor.uint(2, default: 0)))
                }
                deck.beatAnchors = deck.beatGrid.count
            case 64: deck.cues.insert(body.index(2)); deck.cuePackets[body.index(2)] = packet
            case 65: deck.cues.remove(body.index(2)); deck.cuePackets.removeValue(forKey: body.index(2))
            case 67:
                let cue = Int32(truncatingIfNeeded: body.uint(2, default: 0))
                deck.loops.insert(cue); deck.loopPackets[cue] = packet
                if let start = body.loopBoundary(3), let end = body.loopBoundary(4), end > start {
                    deck.loopRegions[cue] = DeckLoopRegion(start: start, end: end, status: body.uint(7, default: 0))
                } else { deck.loopRegions[cue] = nil }
            case 68:
                let cue = Int32(truncatingIfNeeded: body.uint(2, default: 0))
                deck.loops.remove(cue); deck.loopPackets.removeValue(forKey: cue); deck.loopRegions[cue] = nil
            case 69: deck.overview = packet.image
            case 70: deck.title = body.text(2)
            case 71: deck.artist = body.text(2)
            case 73: deck.loaded = true
            default: break
            }
            deck.lastUpdate = received
            if decks.count < 16 || decks[index] != nil { decks[index] = deck }
            return
        }
        switch family {
        case 1: appVersion = body.text(2)
        case 10:
            let title = body.text(1)
            if title != libraryTitle { libraryRows = [:] }
            libraryTitle = title
        case 80:
            let count = body.uint(1, default: 0)
            libraryRowCount = count
            libraryRows = libraryRows.filter { UInt64($0.key) < count }
        case 82: selectedLibraryRow = body.index(1)
        case 85:
            for (field, value) in body.values {
                guard case .bytes(let bytes) = value, let item = Body(bytes) else { continue }
                let row = item.index(1)
                guard libraryRows.count < 500 || libraryRows[row] != nil else { continue }
                switch field {
                case 4:
                    libraryRows[row] = LibraryRow(id: row, title: item.text(2), artist: item.text(3),
                        tempo: item.uint(6).map(Double.init), key: named("key", depth: 1),
                        duration: item.uint(7).map(Double.init), artwork: imageCache[item.index(11)], artIndex: item.index(11), kind: "track", packet: packet)
                case 3:
                    libraryRows[row] = LibraryRow(id: row, title: item.text(2), artist: item.text(5), tempo: nil,
                        key: "", duration: nil, artwork: imageCache[item.index(6)], artIndex: item.index(6), kind: "playlist", packet: packet)
                case 2,5:
                    libraryRows[row] = LibraryRow(id: row, title: item.text(2), artist: "", tempo: nil,
                        key: "", duration: nil, artIndex: nil, kind: field == 2 ? "label" : "button", packet: packet)
                default: break
                }
            }
        default: break
        }
    }
}

private struct Body {
    let values: [(UInt64, WireValue)]
    init?(_ packet: DebugPacket) {
        guard let outer = try? SystemOneDecoder.wireFields(packet.payload),
              case .bytes(let bytes) = outer.first?.1 else { return nil }
        self.init(bytes)
    }
    init?(_ bytes: [UInt8]) {
        guard let fields = try? SystemOneDecoder.wireFields(bytes) else { return nil }
        values = fields
    }
    func value(_ number: UInt64) -> WireValue? { values.last { $0.0 == number }?.1 }
    func text(_ number: UInt64) -> String {
        guard case .bytes(let bytes) = value(number) else { return "" }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
    func uint(_ number: UInt64) -> UInt64? {
        guard case .integer(let integer) = value(number) else { return nil }
        return integer
    }
    func uint(_ number: UInt64, default fallback: UInt64) -> UInt64 { uint(number) ?? fallback }
    func index(_ number: UInt64) -> UInt32 { UInt32(truncatingIfNeeded: uint(number, default: 0)) }
    func loopBoundary(_ number: UInt64) -> Double? {
        guard let encoded = value(number) else { return 0 }
        guard case .fixed64(let bits) = encoded else { return nil }
        let result = Double(bitPattern: bits)
        return result.isFinite ? result : nil
    }
    func number(_ number: UInt64) -> Double? {
        let result: Double
        switch value(number) {
        case .fixed64(let bits): result = Double(bitPattern: bits)
        case .fixed32(let bits): result = Double(Float(bitPattern: bits))
        case .integer(let value): result = Double(value)
        default: return nil
        }
        return result.isFinite ? result : nil
    }
}
