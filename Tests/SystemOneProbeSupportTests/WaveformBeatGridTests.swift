import XCTest
@testable import SystemOneProbeSupport

final class WaveformBeatGridTests: XCTestCase {
    func testSampleCoordinatesAndIntermediateBeats() {
        let anchors = [WaveformBeatAnchor(positionInSamples: 44100, positionInBeats: 0),
                       WaveformBeatAnchor(positionInSamples: 132300, positionInBeats: 4)]
        let lines = WaveformBeatGrid.lines(anchors: anchors, sampleRate: 44100)
        XCTAssertEqual(lines.map(\.seconds), [1, 1.5, 2, 2.5, 3])
        XCTAssertEqual(lines.map(\.beat), [0, 1, 2, 3, 4])
        XCTAssertEqual(lines.map(\.received), [true, false, false, false, true])
        XCTAssertEqual(lines.map(\.downbeat), [true, false, false, false, true])
    }

    func testVariableTempoUsesEachAdjacentAnchorPair() {
        let anchors = [WaveformBeatAnchor(positionInSamples: 0, positionInBeats: 0),
                       WaveformBeatAnchor(positionInSamples: 8, positionInBeats: 4),
                       WaveformBeatAnchor(positionInSamples: 20, positionInBeats: 8)]
        let lines = WaveformBeatGrid.lines(anchors: anchors, sampleRate: 2)
        XCTAssertEqual(lines.map(\.seconds), [0, 1, 2, 3, 4, 5.5, 7, 8.5, 10])
    }

    func testInvalidAndMissingSpansDoNotInventIntermediateBeats() {
        for next in [WaveformBeatAnchor(positionInSamples: -1, positionInBeats: 4),
                     WaveformBeatAnchor(positionInSamples: .nan, positionInBeats: 4),
                     WaveformBeatAnchor(positionInSamples: 10, positionInBeats: -1),
                     WaveformBeatAnchor(positionInSamples: 10, positionInBeats: 100)] {
            let lines = WaveformBeatGrid.lines(anchors: [.init(positionInSamples: 0, positionInBeats: 0), next], sampleRate: 1)
            XCTAssertTrue(lines.allSatisfy(\.received))
        }
    }

    func testUnverifiedTrackStartAndInvalidRateDoNotProduceAnOverlay() {
        let anchors = [WaveformBeatAnchor(positionInSamples: 0, positionInBeats: 0)]
        XCTAssertTrue(WaveformBeatGrid.lines(anchors: anchors, sampleRate: 44100, trackStart: 100).isEmpty)
        XCTAssertTrue(WaveformBeatGrid.lines(anchors: anchors, sampleRate: 0).isEmpty)
    }
}
