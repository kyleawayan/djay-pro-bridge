import Foundation

public struct WaveformBeatAnchor: Equatable, Sendable {
    public let positionInSamples: Double
    public let positionInBeats: Int32
    public init(positionInSamples: Double, positionInBeats: Int32) {
        self.positionInSamples = positionInSamples
        self.positionInBeats = positionInBeats
    }
}

public enum WaveformBeatGrid {
    public struct Line: Equatable, Sendable {
        public let seconds: Double
        public let beat: Int32
        public let received: Bool
        public var downbeat: Bool { beat % 4 == 0 }
    }

    public static func lines(anchors: [WaveformBeatAnchor], sampleRate: Double,
                             trackStart: Double = 0) -> [Line] {
        // Captures establish absolute sample coordinates with zero trackStart only.
        guard sampleRate.isFinite, sampleRate > 0, trackStart == 0 else { return [] }
        var result: [Line] = []
        for (index, anchor) in anchors.enumerated() {
            guard anchor.positionInSamples.isFinite, anchor.positionInSamples >= 0 else { continue }
            result.append(Line(seconds: anchor.positionInSamples / sampleRate,
                               beat: anchor.positionInBeats, received: true))
            guard index + 1 < anchors.count else { continue }
            let next = anchors[index + 1]
            let beatSpan = Int64(next.positionInBeats) - Int64(anchor.positionInBeats)
            guard next.positionInSamples.isFinite, next.positionInSamples > anchor.positionInSamples,
                  beatSpan > 1, beatSpan <= 16 else { continue }
            for step in 1..<beatSpan {
                let position = anchor.positionInSamples + (next.positionInSamples - anchor.positionInSamples)
                    * Double(step) / Double(beatSpan)
                result.append(Line(seconds: position / sampleRate,
                                   beat: Int32(Int64(anchor.positionInBeats) + step), received: false))
            }
        }
        return result
    }
}
