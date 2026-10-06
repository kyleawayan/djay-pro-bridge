import XCTest
@testable import SystemOneProbeSupport

final class MessageAssemblerTests: XCTestCase {
    func testFragmentsAreConcatenatedBeforeUnpacking() {
        var assembler = MessageAssembler()
        XCTAssertNil(assembler.consume([0xf0,0x70,0,0,2,0,1,2,3,0xf7], time: 0).frame)
        XCTAssertEqual(assembler.consume([0xf0,0x70,1,0,2,0,4,5,0xf7], time: 0.1).frame,
                       [0xf0,0x70,0,0,1,0,1,2,3,4,5,0xf7])
    }
    func testMissingAndExpiredGroupsDoNotProduceMessages() {
        var assembler = MessageAssembler()
        XCTAssertNil(assembler.consume([0xf0,0x70,1,0,2,0,4,0xf7], time: 0).frame)
        _ = assembler.consume([0xf0,0x70,0,0,2,0,1,0xf7], time: 1)
        XCTAssertNil(assembler.consume([0xf0,0x70,1,0,2,0,2,0xf7], time: 12).frame)
    }
    func testSinglePacketStartsANewGroupAndInvalidHeaderIsRejected() {
        var assembler = MessageAssembler()
        _ = assembler.consume([0xf0,0x70,0,0,2,0,1,0xf7], time: 0)
        let single: [UInt8] = [0xf0,0x70,0,0,1,0,4,0xf7]
        XCTAssertEqual(assembler.consume(single, time: 0.1).frame, single)
        XCTAssertNil(assembler.consume([0xf0,0x70,0,0,0,0,4,0xf7], time: 0.2).frame)
    }
}
