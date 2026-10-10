import Foundation

public struct TelemetryTimecodeClock {
    public let deckIndex: UInt32
    private var overview = OverviewState()
    private var sampleTime: TimeInterval?

    public init(deckIndex: UInt32) { self.deckIndex = deckIndex }

    public mutating func consume(_ packet: DebugPacket, at time: TimeInterval) {
        guard packet.deckIndex == deckIndex, let field = packet.field,
              [UInt64(50), 51, 55].contains(field) else { return }
        overview.consume(packet)
        // Metadata can announce a replacement track before its first playhead update.
        sampleTime = field == 51 ? time : nil
    }

    public func seconds(at time: TimeInterval) -> Double? {
        guard let sampleTime, let deck = overview.decks[deckIndex],
              let elapsed = deck.elapsed, let duration = deck.duration,
              let rate = deck.velocity, elapsed.isFinite, duration.isFinite,
              duration > 0, rate.isFinite else { return nil }
        let age = time - sampleTime
        // Stop output on lost telemetry instead of free-running through a disconnect.
        guard age.isFinite, age >= 0, age <= 0.5 else { return nil }
        let result = elapsed + age * rate
        guard result.isFinite else { return nil }
        return min(duration, max(0, result))
    }
}
