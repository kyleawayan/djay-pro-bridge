import Foundation
import XCTest
@testable import SystemOneProbeSupport

final class PacketStoreTests: XCTestCase {
    private func frame(_ field: UInt64, _ body: [UInt8]) -> [UInt8] {
        var tag = field << 3 | 2
        var data: [UInt8] = []
        while tag > 127 { data.append(UInt8(tag & 127) | 128); tag >>= 7 }
        data.append(UInt8(tag)); data.append(UInt8(body.count)); data += body
        var output: [UInt8] = [0xf0,0x70,0,0,1,0]
        var bits = 0
        var value: UInt64 = 0
        for byte in data {
            value |= UInt64(byte) << bits; bits += 8
            while bits >= 7 { output.append(UInt8(value & 127)); value >>= 7; bits -= 7 }
        }
        if bits > 0 { output.append(UInt8(value & 127)) }
        return output + [0xf7]
    }
    private func position(_ value: Double) -> [UInt8] {
        [17] + (0..<8).map { UInt8((value.bitPattern >> ($0 * 8)) & 255) }
    }
    private func record(_ frame: [UInt8], store: inout PacketStore, time: Double = 0) {
        store.record(raw: frame, decodedFrame: frame, packet: PacketDebugger.inspect(frame, catalog: nil),
                     elapsed: time, assembly: "Single packet", received: Date(timeIntervalSince1970: time))
    }
    func testDeckPacketsAndChangeHistoryAreIsolated() {
        var store = PacketStore()
        let first = frame(51, position(0.25))
        let second = frame(51, [8,1] + position(0.75))
        record(first, store: &store)
        record(second, store: &store, time: 1)
        record(frame(51, position(0.3)), store: &store, time: 2)
        XCTAssertEqual(store.latest[.deck(0)]?[51]?.count, 2)
        XCTAssertEqual(store.latest[.deck(1)]?[51]?.count, 1)
        XCTAssertEqual(store.latest[.deck(1)]?[51]?.raw, second)
        XCTAssertEqual(store.latest[.deck(1)]?[51]?.received, Date(timeIntervalSince1970: 1))
        XCTAssertNil(store.latest[.global]?[51])
    }
    func testOmittedAndExplicitZeroUseSameDeck() {
        var store = PacketStore()
        record(frame(51, position(0.1)), store: &store)
        record(frame(51, [8,0] + position(0.2)), store: &store)
        XCTAssertEqual(store.latest.count, 1)
        XCTAssertEqual(store.latest[.deck(0)]?[51]?.count, 2)
    }
    func testGlobalImageSlotsDoNotBecomeDecksOrOverwriteEachOther() {
        var store = PacketStore()
        let a = frame(90, [18,3,0xff,0xd8,0xff])
        let b = frame(90, [8,3,18,4,0xff,0xd8,0xff,0])
        record(a, store: &store)
        record(b, store: &store)
        XCTAssertEqual(store.latest[.global]?[90]?.count, 2)
        XCTAssertEqual(store.images.count, 2)
        XCTAssertEqual(store.images[0]?.raw, a)
        XCTAssertEqual(store.images[3]?.raw, b)
        XCTAssertEqual(store.images[3]?.count, 1)
        XCTAssertNil(store.latest[.deck(3)])
    }
    func testKeepaliveHasNoDeckScope() {
        var store = PacketStore()
        record(frame(1, [18,3,49,46,48]), store: &store)
        XCTAssertEqual(store.latest[.global]?[1]?.count, 1)
        XCTAssertEqual(PacketScope.deck(0).title, "Deck 1 · index 0")
        XCTAssertEqual(PacketScope.deck(1).title, "Deck 2 · index 1")
    }
}
