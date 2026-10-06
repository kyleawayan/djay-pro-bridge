import Foundation
import XCTest
@testable import SystemOneProbeSupport

final class MessageDecoderTests: XCTestCase {
    private func varint(_ input: UInt64) -> [UInt8] {
        var value = input, result: [UInt8] = []
        repeat {
            let byte = UInt8(value & 127)
            value >>= 7
            result.append(byte | (value > 0 ? 128 : 0))
        } while value > 0
        return result
    }

    private func bytesField(_ index: UInt64, _ bytes: [UInt8]) -> [UInt8] {
        varint(index << 3 | 2) + varint(UInt64(bytes.count)) + bytes
    }

    private func doubleField(_ index: UInt64, _ value: Double) -> [UInt8] {
        varint(index << 3 | 1) + (0..<8).map { UInt8((value.bitPattern >> ($0 * 8)) & 255) }
    }

    private func frame(_ payload: [UInt8]) -> [UInt8] {
        var result: [UInt8] = [0xf0, 0x70, 0, 0, 1, 0]
        var accumulator: UInt64 = 0, bits = 0
        for byte in payload {
            accumulator |= UInt64(byte) << bits
            bits += 8
            while bits >= 7 {
                result.append(UInt8(accumulator & 127))
                accumulator >>= 7
                bits -= 7
            }
        }
        if bits > 0 { result.append(UInt8(accumulator & 127)) }
        return result + [0xf7]
    }

    func testRealtimeNumbersAndExplicitIndex() {
        let body = [UInt8(8), 1] + doubleField(2, 0.25) + doubleField(3, -1.125) + doubleField(4, 1000)
        guard case .realtime(let data) = SystemOneDecoder.decode(frame(bytesField(51, body))) else { return XCTFail("Expected realtime data") }
        XCTAssertEqual(data.deckIndex, 1)
        XCTAssertEqual(data.position, 0.25)
        XCTAssertEqual(data.rate, -1.125)
        XCTAssertEqual(data.senderClock, 1000)
    }

    func testOmittedProto3ScalarsUseSchemaDefaults() {
        guard case .realtime(let data) = SystemOneDecoder.decode(frame(bytesField(51, doubleField(2, 0.4)))) else { return XCTFail("Expected realtime data") }
        XCTAssertEqual(data.deckIndex, 0)
        XCTAssertEqual(data.rate, 0)
        XCTAssertEqual(data.senderClock, 0)
    }

    func testVersionIsRestrictedToVersionSyntax() {
        XCTAssertEqual(SystemOneDecoder.decode(frame(bytesField(1, bytesField(2, Array("1.2.3".utf8))))), .identification(version: "1.2.3"))
        XCTAssertEqual(SystemOneDecoder.decode(frame(bytesField(1, bytesField(2, Array("PRIVATE_TEXT_PLACEHOLDER".utf8))))), .identification(version: nil))
    }

    func testImageBytesAreNotReturnedByDecoder() {
        let bytes: [UInt8] = [0xff, 0xd8, 0xff, 0, 1, 2]
        XCTAssertEqual(SystemOneDecoder.decode(frame(bytesField(90, bytesField(2, bytes)))), .image(bytes: 6, isJPEG: true))
    }

    func testUnknownEnvelopeAndUnsupportedFieldRemainUnknown() {
        var multipart = frame(bytesField(1, []))
        multipart[4] = 2
        XCTAssertEqual(SystemOneDecoder.decode(multipart), .unknown(field: nil))
        XCTAssertEqual(SystemOneDecoder.decode(frame(bytesField(110, [0, 1, 2]))), .unknown(field: 110))
    }

    func testMalformedAndNonfiniteValuesAreRejected() {
        XCTAssertEqual(SystemOneDecoder.decode(frame([10, 8, 1])), .malformed)
        XCTAssertEqual(SystemOneDecoder.decode(frame([0])), .malformed)
        XCTAssertEqual(SystemOneDecoder.decode(frame(Array(repeating: 0xff, count: 11))), .malformed)
        XCTAssertEqual(SystemOneDecoder.decode(frame(bytesField(51, doubleField(2, .nan)))), .malformed)
    }
}
