import XCTest
@testable import SystemOneProbeSupport

final class CoalescedUpdateTests: XCTestCase {
    @MainActor func testPacketBurstPublishesLatestStateOnNextTurn() async {
        var work: [@MainActor () -> Void] = []
        var value = 0
        var published: [Int] = []
        let updates = CoalescedUpdate(schedule: { work.append($0) }) { published.append(value) }
        for next in 1...100 { value = next; updates.request() }
        XCTAssertEqual(work.count, 1)
        XCTAssertTrue(published.isEmpty)
        work.removeFirst()()
        XCTAssertEqual(published, [100])
        value = 101; updates.request()
        XCTAssertEqual(work.count, 1)
        work.removeFirst()()
        XCTAssertEqual(published, [100,101])
    }
    @MainActor func testFreezeRetainsNewestValueAndResumeNeedsNoTimer() async {
        var work: [@MainActor () -> Void] = []
        var value = 1
        var published: [Int] = []
        let updates = CoalescedUpdate(schedule: { work.append($0) }) { published.append(value) }
        updates.request()
        updates.isPaused = true
        work.removeFirst()()
        value = 2; updates.request()
        XCTAssertTrue(published.isEmpty)
        XCTAssertTrue(work.isEmpty)
        updates.isPaused = false
        work.removeFirst()()
        XCTAssertEqual(published, [2])
    }
    @MainActor func testResetInvalidatesQueuedOldSession() async {
        var work: [@MainActor () -> Void] = []
        var published = 0
        let updates = CoalescedUpdate(schedule: { work.append($0) }) { published += 1 }
        updates.request()
        updates.cancelPending()
        updates.request()
        work.removeFirst()()
        XCTAssertEqual(published, 0)
        work.removeFirst()()
        XCTAssertEqual(published, 1)
    }
    @MainActor func testOfflineFlushDoesNotPublishTwice() async {
        var work: [@MainActor () -> Void] = []
        var published = 0
        let updates = CoalescedUpdate(schedule: { work.append($0) }) { published += 1 }
        updates.request()
        updates.flushNow()
        XCTAssertEqual(published, 1)
        work.removeFirst()()
        XCTAssertEqual(published, 1)
    }
}
