import Foundation
import XCTest
@testable import SystemOneProbeSupport

final class PathChecksTests: XCTestCase {
    func testRootTerminatesWithoutParentTraversal() {
        XCTAssertEqual(ancestorDirectories(of: URL(fileURLWithPath: "/")).map(\.path), ["/"])
    }

    func testAncestorsIncludeRootExactlyOnce() {
        let url = URL(fileURLWithPath: "/tmp/my-probe/capture", isDirectory: true)
        XCTAssertEqual(ancestorDirectories(of: url).map(\.path), ["/tmp/my-probe/capture", "/tmp/my-probe", "/tmp", "/"])
    }
}
