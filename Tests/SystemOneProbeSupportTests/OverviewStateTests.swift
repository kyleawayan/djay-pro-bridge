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
    func testTimecodeInterpolatesSelectedDeckAndExpires() {
        var clock = TelemetryTimecodeClock(deckIndex: 0)
        clock.consume(packet(50, double(4, 48000) + integer(5, 4800000)), at: 0)
        XCTAssertNil(clock.seconds(at: 0))
        clock.consume(packet(51, double(2, 0.25) + double(3, 1.5)), at: 1)
        XCTAssertEqual(clock.seconds(at: 1.2)!, 25.3, accuracy: 0.0001)
        clock.consume(packet(51, double(2, 0.9), deck: 1), at: 1.3)
        XCTAssertEqual(clock.seconds(at: 1.4)!, 25.6, accuracy: 0.0001)
        XCTAssertNil(clock.seconds(at: 1.501))
        XCTAssertNil(clock.seconds(at: 0.9))
    }
    func testTimecodePauseSeekReverseAndTrackReplacement() {
        var clock = TelemetryTimecodeClock(deckIndex: 0)
        let metadata = packet(50, double(4, 48000) + integer(5, 4800000))
        clock.consume(metadata, at: 0)
        clock.consume(packet(51, double(2, 0.5)), at: 1)
        XCTAssertEqual(clock.seconds(at: 1.4), 50)
        clock.consume(packet(51, double(2, 0.1) + double(3, -1)), at: 2)
        XCTAssertEqual(clock.seconds(at: 2.25), 9.75)
        clock.consume(metadata, at: 2.3)
        XCTAssertNil(clock.seconds(at: 2.3))
        clock.consume(packet(51, double(2, 0.8)), at: 3)
        XCTAssertEqual(clock.seconds(at: 3), 80)
        clock.consume(packet(55, []), at: 3.1)
        XCTAssertNil(clock.seconds(at: 3.1))
    }
    func testTimecodeClampsToTrackBoundsAndRejectsMissingDuration() {
        var clock = TelemetryTimecodeClock(deckIndex: 0)
        clock.consume(packet(51, double(2, 0.5)), at: 0)
        XCTAssertNil(clock.seconds(at: 0))
        clock.consume(packet(50, double(4, 48000) + integer(5, 4800000)), at: 1)
        clock.consume(packet(51, double(2, -0.1) + double(3, -1)), at: 2)
        XCTAssertEqual(clock.seconds(at: 2), 0)
        clock.consume(packet(51, double(2, 1) + double(3, 1)), at: 3)
        XCTAssertEqual(clock.seconds(at: 3.25), 100)
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
    func testReusedImageSlotsDoNotChangePreviouslyAssignedArtwork() {
        var state = OverviewState()
        func image(_ bytes: [UInt8]) -> DebugPacket {
            DebugPacket(field: 90, name: "synthetic", payload: blob(90, []), fields: [], image: Data(bytes),
                        waveform: nil, waveformOffset: nil, status: "synthetic", deckIndex: nil, cacheIndex: 4)
        }
        state.consume(image([1,2,3]))
        state.consume(packet(85, blob(4, integer(1,0) + string(2,"Track A") + integer(11,4)), deck: nil))
        state.consume(packet(56, integer(2,4)))
        state.consume(image([4,5,6]))
        state.consume(packet(85, blob(4, integer(1,1) + string(2,"Track B") + integer(11,4)), deck: nil))
        XCTAssertEqual(state.libraryRows[0]?.artwork, Data([1,2,3]))
        XCTAssertEqual(state.libraryRows[1]?.artwork, Data([4,5,6]))
        XCTAssertEqual(state.decks[0]?.artwork, Data([1,2,3]))
        state.consume(packet(56, integer(2,4)))
        XCTAssertEqual(state.decks[0]?.artwork, Data([4,5,6]))
        state.consume(packet(55, []))
        XCTAssertNil(state.decks[0]?.artwork)
    }

}
