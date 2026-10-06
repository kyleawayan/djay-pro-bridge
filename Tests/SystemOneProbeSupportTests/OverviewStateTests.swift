import Foundation
import XCTest
@testable import SystemOneProbeSupport

final class OverviewStateTests: XCTestCase {
    private func varint(_ n: UInt64) -> [UInt8] {
        var n = n, bytes: [UInt8] = []
        while n > 127 { bytes.append(UInt8(n & 127) | 128); n >>= 7 }
        return bytes + [UInt8(n)]
    }
    private func integer(_ key: UInt64, _ value: UInt64) -> [UInt8] { varint(key << 3) + varint(value) }
    private func blob(_ key: UInt64, _ bytes: [UInt8]) -> [UInt8] { varint(key << 3 | 2) + varint(UInt64(bytes.count)) + bytes }
    private func string(_ key: UInt64, _ value: String) -> [UInt8] { blob(key, Array(value.utf8)) }
    private func double(_ key: UInt64, _ value: Double) -> [UInt8] {
        varint(key << 3 | 1) + (0..<8).map { UInt8((value.bitPattern >> ($0 * 8)) & 255) }
    }
    private func packet(_ family: UInt64, _ body: [UInt8], deck: UInt32? = 0, waveform: [UInt8]? = nil, offset: UInt64? = nil) -> DebugPacket {
        DebugPacket(field: family, name: "synthetic", payload: blob(family, body), fields: [], image: nil,
                    waveform: waveform, waveformOffset: offset, status: "synthetic", deckIndex: deck, cacheIndex: nil)
    }
    func testDurationAndElapsedUseReceivedSampleRateAndLength() {
        var state = OverviewState()
        state.consume(packet(50, string(2,"Example track") + string(3,"Example artist") + double(4,48000) + integer(5,4800000)))
        state.consume(packet(51, double(2,0.25) + double(3,1)))
        XCTAssertEqual(state.decks[0]?.duration, 100)
        XCTAssertEqual(state.decks[0]?.elapsed, 25)
        XCTAssertEqual(state.decks[0]?.title, "Example track")
    }
    func testLibraryRetainsEachRowAndSelectionWithoutSendingCommands() {
        var state = OverviewState()
        state.consume(packet(10, string(1,"Example playlist"), deck: nil))
        state.consume(packet(80, integer(1,2), deck: nil))
        state.consume(packet(85, blob(4,string(2,"Example A") + integer(11,4)), deck: nil))
        state.consume(packet(85, blob(4,integer(1,1) + string(2,"Example B") + integer(11,5)), deck: nil))
        state.consume(packet(82, integer(1,1), deck: nil))
        XCTAssertEqual(state.libraryRows.count, 2)
        XCTAssertEqual(state.libraryRows[0]?.title, "Example A")
        XCTAssertEqual(state.libraryRows[1]?.artIndex, 5)
        XCTAssertEqual(state.selectedLibraryRow, 1)
    }
    func testWaveformAndCueStateIsClearedWhenDeckIsCleared() {
        var state = OverviewState()
        state.consume(packet(62, [], waveform: [255,0,0,200], offset: 0))
        state.consume(packet(64, integer(2,3)))
        XCTAssertEqual(state.decks[0]?.detailSampleCount, 1)
        XCTAssertEqual(state.decks[0]?.cues, [3])
        state.consume(packet(55, []))
        XCTAssertEqual(state.decks[0]?.detailSampleCount, 0)
        XCTAssertEqual(state.decks[0]?.cues.count, 0)
    }
    func testBeatJumpAndLoopValuesRemainSeparatePerDeck() {
        var state = OverviewState()
        state.consume(packet(59, string(2,"4 Beats"), deck: 0))
        state.consume(packet(61, string(2,"32 Beats"), deck: 0))
        state.consume(packet(59, string(2,"8 Beats"), deck: 1))
        XCTAssertEqual(state.decks[0]?.loopLabel, "4 Beats")
        XCTAssertEqual(state.decks[0]?.beatJumpLabel, "32 Beats")
        XCTAssertEqual(state.decks[1]?.loopLabel, "8 Beats")
    }
}
