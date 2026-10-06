import Foundation

/// Track-anchored bins keep a pan from selecting different peaks or colors at each screen pixel.
public enum WaveformEnvelope {
    public struct Bar: Equatable, Sendable {
        public let sampleOffset: UInt64
        public let sampleCount: UInt64
        public let red: Double
        public let green: Double
        public let blue: Double
        public let height: Double

        public func x(viewportStart: Double, span: Double, width: Double) -> Double {
            (Double(sampleOffset) - viewportStart) / span * width
        }
    }

    public static func bars(chunks: [UInt64: [UInt8]], viewportStart: Double,
                            span: Double, width: Double) -> [Bar] {
        guard viewportStart.isFinite, span.isFinite, width.isFinite,
              viewportStart >= 0, span > 0, width > 0,
              viewportStart + span < Double(UInt32.max), span / width < Double(UInt32.max) else { return [] }
        let binSize = UInt64(max(1, ceil(span / width)))
        let first = UInt64(viewportStart) / binSize * binSize
        let end = UInt64(ceil(viewportStart + span))
        let ordered = chunks.sorted { $0.key < $1.key }
        var chunkIndex = 0
        var result: [Bar] = []
        var offset = first
        while offset < end {
            var red = 0.0, green = 0.0, blue = 0.0, peak: UInt8 = 0
            var received = 0
            // Include the full bin even at the viewport edge, so entering/leaving never changes its shape.
            for sample in offset..<(offset + binSize) {
                while chunkIndex < ordered.count {
                    let chunk = ordered[chunkIndex]
                    if sample >= chunk.key && sample - chunk.key >= UInt64(chunk.value.count / 4) {
                        chunkIndex += 1
                    } else { break }
                }
                guard chunkIndex < ordered.count else { break }
                let chunk = ordered[chunkIndex]
                guard sample >= chunk.key else { continue }
                let index = Int(sample - chunk.key) * 4
                red += Double(chunk.value[index])
                green += Double(chunk.value[index + 1])
                blue += Double(chunk.value[index + 2])
                peak = max(peak, chunk.value[index + 3])
                received += 1
            }
            if received > 0 {
                let scale = Double(received) * 255
                result.append(Bar(sampleOffset: offset, sampleCount: binSize,
                                  red: red / scale, green: green / scale, blue: blue / scale,
                                  height: Double(peak) / 255))
            }
            offset += binSize
        }
        return result
    }
}
