import XCTest
@testable import SystemOneProbeSupport

final class WaveformStateTests: XCTestCase {
    private func varint(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        while value > 127 { bytes.append(UInt8(value & 127) | 128); value >>= 7 }
        return bytes + [UInt8(value)]
    }
    private func blob(_ field: UInt64, _ bytes: [UInt8]) -> [UInt8] {
        varint(field << 3 | 2) + varint(UInt64(bytes.count)) + bytes
    }
    private func double(_ field: UInt64, _ value: Double) -> [UInt8] {
        varint(field << 3 | 1) + (0..<8).map { UInt8((value.bitPattern >> ($0 * 8)) & 255) }
    }
    private func packet(_ family: UInt64, _ body: [UInt8]) -> DebugPacket {
        DebugPacket(field: family, name: "synthetic", payload: blob(family, body), fields: [], image: nil,
                    waveform: nil, waveformOffset: nil, status: "synthetic", deckIndex: 0, cacheIndex: nil)
    }
    func testRetainsAnchorsAndTrackSampleCoordinatesThenClearsThem() {
        var state = OverviewState()
        state.consume(packet(50, double(4, 44100) + varint(5 << 3) + varint(88200)))
        state.consume(packet(63, blob(2, double(1, 22050)) + blob(2, double(1, 66150) + [16, 4])))
        XCTAssertEqual(state.decks[0]?.sampleRate, 44100)
        XCTAssertEqual(state.decks[0]?.lengthInSamples, 88200)
        XCTAssertEqual(state.decks[0]?.beatGrid.map(\.positionInBeats), [0, 4])
        XCTAssertEqual(state.decks[0]?.beatGrid.map(\.positionInSamples), [22050, 66150])
        XCTAssertEqual(state.decks[0]?.trackStart, 0)
        state.consume(packet(55, []))
        XCTAssertEqual(state.decks[0]?.beatGrid.count, 0)
        XCTAssertNil(state.decks[0]?.sampleRate)
    }
    func testEmptyGridReplacesPriorGridAndInvalidPositionIsNotReplacedWithZero() {
        var state = OverviewState()
        state.consume(packet(63, blob(2, double(1, .nan)) + blob(2, double(1, 44100))))
        XCTAssertEqual(state.decks[0]?.beatGrid.count, 1)
        XCTAssertEqual(state.decks[0]?.beatGrid.first?.positionInSamples, 44100)
        state.consume(packet(63, []))
        XCTAssertEqual(state.decks[0]?.beatGrid.count, 0)
    }
}
