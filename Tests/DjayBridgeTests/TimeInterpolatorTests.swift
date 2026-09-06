import XCTest
@testable import DjayBridge

final class TimeInterpolatorTests: XCTestCase {

    func testPausedReturnsBaseExactly() {
        var interp = TimeInterpolator()
        interp.update(
            elapsedTime: "0:10", remainingTime: "-1:00",
            isPlaying: false, bpmPercent: "0.0%", sampleTime: Date()
        )
        XCTAssertEqual(interp.interpolatedElapsed()!, 10, accuracy: 0.001)
        XCTAssertEqual(interp.interpolatedRemaining()!, 60, accuracy: 0.001)
    }

    func testSampleTimeInThePastAdvancesBaseline() {
        var interp = TimeInterpolator()
        // Read happened 0.5s ago → interpolated elapsed should be ~10.5.
        interp.update(
            elapsedTime: "0:10", remainingTime: nil,
            isPlaying: true, bpmPercent: "0.0%",
            sampleTime: Date().addingTimeInterval(-0.5)
        )
        let val = interp.interpolatedElapsed()!
        XCTAssertGreaterThan(val, 10.4)
        XCTAssertLessThan(val, 10.7)
    }

    func testFreeRunIsCapped() {
        var interp = TimeInterpolator()
        // Read 100s ago while playing — without a cap this would read ~110s.
        interp.update(
            elapsedTime: "0:10", remainingTime: "-2:00",
            isPlaying: true, bpmPercent: "0.0%",
            sampleTime: Date().addingTimeInterval(-100)
        )
        let e = interp.interpolatedElapsed()!
        let r = interp.interpolatedRemaining()!
        XCTAssertEqual(e, 10 + TimeInterpolator.maxInterpolationLead, accuracy: 0.05)
        XCTAssertEqual(r, 120 - TimeInterpolator.maxInterpolationLead, accuracy: 0.05)
    }

    func testRateScalesInterpolation() {
        var interp = TimeInterpolator()
        // +8% pitch → 1.08x. 0.5s of wall time → 0.54 track-seconds.
        interp.update(
            elapsedTime: "0:10", remainingTime: nil,
            isPlaying: true, bpmPercent: "8.0%",
            sampleTime: Date().addingTimeInterval(-0.5)
        )
        let val = interp.interpolatedElapsed()!
        XCTAssertGreaterThan(val, 10.5)
        XCTAssertLessThan(val, 10.62)
    }
}
