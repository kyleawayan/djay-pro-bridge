import XCTest
@testable import SystemOneProbeSupport

final class WaveformEnvelopeTests: XCTestCase {
    private let alternating: [UInt8] = (0..<80).flatMap { i -> [UInt8] in
        i.isMultiple(of: 2) ? [255, 0, 0, 255] : [0, 0, 255, 32]
    }

    func testPanningTranslatesExistingBarsWithoutChangingHeightOrColor() {
        let first = WaveformEnvelope.bars(chunks: [0: alternating], viewportStart: 2.25, span: 40, width: 10)
        let next = WaveformEnvelope.bars(chunks: [0: alternating], viewportStart: 3.75, span: 40, width: 10)
        let matching = Dictionary(uniqueKeysWithValues: next.map { ($0.sampleOffset, $0) })
        XCTAssertGreaterThan(first.count, 5)
        for bar in first {
            guard let moved = matching[bar.sampleOffset] else { continue }
            XCTAssertEqual(bar, moved)
            XCTAssertEqual(moved.x(viewportStart: 3.75, span: 40, width: 10)
                           - bar.x(viewportStart: 2.25, span: 40, width: 10), -0.375, accuracy: 1e-12)
        }
    }

    func testDownsamplingPreservesPeaksAndAveragesAllColors() {
        let bars = WaveformEnvelope.bars(chunks: [0: alternating], viewportStart: 0, span: 40, width: 10)
        XCTAssertEqual(bars.count, 10)
        for bar in bars {
            XCTAssertEqual(bar.height, 1)
            XCTAssertEqual(bar.red, 0.5)
            XCTAssertEqual(bar.blue, 0.5)
            XCTAssertEqual(bar.green, 0)
        }
    }

    func testChunkBoundariesDoNotChangeAggregation() {
        let whole = WaveformEnvelope.bars(chunks: [0: alternating], viewportStart: 1.5, span: 40, width: 10)
        let split = WaveformEnvelope.bars(chunks: [0: Array(alternating.prefix(28)), 7: Array(alternating.dropFirst(28))],
                                          viewportStart: 1.5, span: 40, width: 10)
        XCTAssertEqual(whole, split)
    }

    func testMissingRegionsAreNotInventedAndIncompleteSamplesAreIgnored() {
        let bars = WaveformEnvelope.bars(chunks: [4: [0, 255, 0, 128, 99]], viewportStart: 0, span: 12, width: 3)
        XCTAssertEqual(bars.count, 1)
        XCTAssertEqual(bars.first?.sampleOffset, 4)
        XCTAssertEqual(bars.first?.green, 1)
        XCTAssertEqual(bars.first?.height, 128.0 / 255)
    }

    func testInvalidViewportsDoNotProduceGeometry() {
        for start in [Double.nan, Double.infinity, -1, Double(UInt32.max)] {
            XCTAssertTrue(WaveformEnvelope.bars(chunks: [0: alternating], viewportStart: start, span: 40, width: 10).isEmpty)
        }
        XCTAssertTrue(WaveformEnvelope.bars(chunks: [0: alternating], viewportStart: 0, span: 40, width: 0).isEmpty)
    }
}
