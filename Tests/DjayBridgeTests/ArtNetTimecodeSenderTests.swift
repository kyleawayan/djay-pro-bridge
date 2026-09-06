import XCTest
@testable import DjayBridge

final class ArtNetTimecodeSenderTests: XCTestCase {

    func testHeaderIsArtNetTimecode() {
        let p = ArtNetTimecodeSender.buildPacket(seconds: 0, fps: 30, typeByte: 3)
        XCTAssertEqual(p.count, 19)
        XCTAssertEqual(Array(p.prefix(8)), Array("Art-Net".utf8) + [0])
        // OpCode 0x9700, low byte first
        XCTAssertEqual(p[8], 0x00)
        XCTAssertEqual(p[9], 0x97)
        // Protocol version 14, high byte first
        XCTAssertEqual(p[10], 0)
        XCTAssertEqual(p[11], 14)
    }

    func testTimeFieldsAt30fps() {
        // 1h 2m 3s + 15 frames at 30fps → 3723.5s
        let p = ArtNetTimecodeSender.buildPacket(seconds: 3723.5, fps: 30, typeByte: 3)
        XCTAssertEqual(p[14], 15)  // Frames
        XCTAssertEqual(p[15], 3)   // Seconds
        XCTAssertEqual(p[16], 2)   // Minutes
        XCTAssertEqual(p[17], 1)   // Hours
        XCTAssertEqual(p[18], 3)   // Type
    }

    func testFramesWrapAtFramerate() {
        // 0.999s at 25fps → frame 24, still in second 0
        let p = ArtNetTimecodeSender.buildPacket(seconds: 0.999, fps: 25, typeByte: 1)
        XCTAssertEqual(p[14], 24)  // Frames
        XCTAssertEqual(p[15], 0)   // Seconds
    }

    func testHoursWrapAt24() {
        let p = ArtNetTimecodeSender.buildPacket(seconds: 25 * 3600, fps: 30, typeByte: 3)
        XCTAssertEqual(p[17], 1)  // 25h wraps to 1
    }

    func testFramerateParsing() {
        XCTAssertEqual(ArtNetTimecodeSender.Framerate.parse("24")?.typeByte, 0)
        XCTAssertEqual(ArtNetTimecodeSender.Framerate.parse("25")?.typeByte, 1)
        XCTAssertEqual(ArtNetTimecodeSender.Framerate.parse("29.97")?.typeByte, 2)
        XCTAssertEqual(ArtNetTimecodeSender.Framerate.parse("30")?.typeByte, 3)
        XCTAssertNil(ArtNetTimecodeSender.Framerate.parse("60"))
    }
}
