import XCTest
@testable import SystemOneProbeSupport

final class StartupKeepaliveTests: XCTestCase {
    func testStartupMessageIsKeepaliveAndIdentifiesOurApplication() throws {
        let frame = StartupKeepalive.frame()
        XCTAssertEqual(frame.count, 43)
        XCTAssertTrue(frame.prefix(6).elementsEqual([0xf0,0x70,0,0,1,0]))
        XCTAssertEqual(SystemOneDecoder.decode(frame), .identification(version: "0.1.0"))
        let unpacked = try SystemOneDecoder.unpack(Array(frame.dropFirst(6).dropLast()))
        let outer = try SystemOneDecoder.wireFields(unpacked)
        XCTAssertEqual(outer.count, 1)
        XCTAssertEqual(outer.first?.0, 1)
        guard case .bytes(let body) = outer.first?.1 else { return XCTFail("Missing keepalive body") }
        let fields = try SystemOneDecoder.wireFields(body)
        guard case .bytes(let name) = fields.first?.1 else { return XCTFail("Missing appName") }
        XCTAssertEqual(String(bytes: name, encoding: .utf8), "System One Inspector")
    }
}
