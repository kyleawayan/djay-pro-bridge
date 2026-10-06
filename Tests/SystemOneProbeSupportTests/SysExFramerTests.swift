import Foundation
import XCTest
@testable import SystemOneProbeSupport

final class SysExFramerTests: XCTestCase {
    func testFragmentedMessageSurvivesPacketBoundariesAndRealtimeBytes() {
        var framer = SysExFramer()
        XCTAssertEqual(framer.consume(Data([0xf0, 0x70, 0xf8, 0x01])), [])
        XCTAssertEqual(framer.consume(Data([0xfa, 0x02, 0xf7])), [.message([0xf0, 0x70, 0x01, 0x02, 0xf7])])
        XCTAssertTrue(framer.partial.isEmpty)
    }

    func testMultipleMessagesAndUnrelatedMidiInOnePacket() {
        var framer = SysExFramer()
        let bytes: [UInt8] = [0x90, 0x40, 0x7f, 0xf0, 0x7d, 0x01, 0xf7, 0xf0, 0x7d, 0x02, 0xf7]
        XCTAssertEqual(framer.consume(Data(bytes)), [.message([0xf0, 0x7d, 0x01, 0xf7]), .message([0xf0, 0x7d, 0x02, 0xf7])])
    }

    func testUnexpectedStatusDiscardsPartialWithoutInventingACompleteMessage() {
        var framer = SysExFramer()
        XCTAssertEqual(framer.consume(Data([0xf0, 0x7d, 0x90, 0x40, 0x7f, 0xf7])), [.interrupted(2)])
        XCTAssertTrue(framer.partial.isEmpty)
    }

    func testNewStartRecoversFromAnUnfinishedMessage() {
        var framer = SysExFramer()
        XCTAssertEqual(framer.consume(Data([0xf0, 0x7d, 0x01, 0xf0, 0x7d, 0xf7])), [.interrupted(3), .message([0xf0, 0x7d, 0xf7])])
    }

    func testLimitIncludesFramingBytesAndRecoversAfterOverflow() {
        var framer = SysExFramer(maximumMessageBytes: 4)
        XCTAssertEqual(framer.consume(Data([0xf0, 0x7d, 0x01, 0xf7])), [.message([0xf0, 0x7d, 0x01, 0xf7])])
        XCTAssertEqual(framer.consume(Data([0xf0, 0x7d, 0x01, 0x02, 0x03, 0xf7])), [.oversized(5)])
        XCTAssertEqual(framer.consume(Data([0xf0, 0x7d, 0xf7])), [.message([0xf0, 0x7d, 0xf7])])
    }
}
