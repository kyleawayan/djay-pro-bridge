import Foundation
import XCTest
@testable import SystemOneProbeSupport

final class CaptureCountersTests: XCTestCase {
    func testValidIntegerCountsAccumulate() throws {
        XCTAssertEqual(try CaptureCounters.add(NSNumber(value: 43), to: 10), 53)
        XCTAssertEqual(try CaptureCounters.add(NSNumber(value: 0), to: 53), 53)
    }
    func testOverflowAndInvalidCountsAreRejected() {
        XCTAssertThrowsError(try CaptureCounters.add(NSNumber(value: 1), to: Int.max))
        for value: Any? in [nil, "43", NSNumber(value: -1), NSNumber(value: 1.5), NSNumber(value: true)] {
            XCTAssertThrowsError(try CaptureCounters.add(value, to: 0))
        }
    }
}
