import XCTest
@testable import DjayBridge

final class MainDeckTrackerTests: XCTestCase {

    private func deck(
        title: String? = "Track", isPlaying: Bool = false,
        lineVolume: String? = "100%"
    ) -> DeckInfo {
        DeckInfo(
            title: title, bpm: "120.0", isPlaying: isPlaying,
            lineVolume: lineVolume
        )
    }

    // MARK: - Initial state

    func testNoDecksPlaying_mainIsNil() {
        let tracker = MainDeckTracker()
        let result = tracker.update(
            deck1: deck(), deck2: deck(), crossfader: "50%"
        )
        XCTAssertNil(result)
    }

    // MARK: - First play assignment

    func testDeck1PlaysFirst_becomesMain() {
        let tracker = MainDeckTracker()
        let result = tracker.update(
            deck1: deck(isPlaying: true),
            deck2: deck(),
            crossfader: "50%"
        )
        XCTAssertEqual(result, 1)
    }

    func testDeck2PlaysFirst_becomesMain() {
        let tracker = MainDeckTracker()
        let result = tracker.update(
            deck1: deck(),
            deck2: deck(isPlaying: true),
            crossfader: "50%"
        )
        XCTAssertEqual(result, 2)
    }

    // MARK: - Both playing, first wins

    func testBothPlaying_firstToPlayStaysMain() {
        let tracker = MainDeckTracker()
        // Deck 1 starts first
        tracker.update(
            deck1: deck(isPlaying: true),
            deck2: deck(),
            crossfader: "50%"
        )
        // Deck 2 also starts
        let result = tracker.update(
            deck1: deck(isPlaying: true),
            deck2: deck(isPlaying: true),
            crossfader: "50%"
        )
        XCTAssertEqual(result, 1)
    }

    // MARK: - Pause handoff

    func testMainDeckPauses_handoffToOther() {
        let tracker = MainDeckTracker()
        // Deck 1 is main
        tracker.update(
            deck1: deck(isPlaying: true),
            deck2: deck(isPlaying: true),
            crossfader: "50%"
        )
        // Deck 1 pauses
        let result = tracker.update(
            deck1: deck(isPlaying: false),
            deck2: deck(isPlaying: true),
            crossfader: "50%"
        )
        XCTAssertEqual(result, 2)
    }

    // MARK: - Track load handoff

    func testMainDeckLoadsNewTrack_handoffToOther() {
        let tracker = MainDeckTracker()
        // Deck 1 is main, playing "Song A"
        tracker.update(
            deck1: deck(title: "Song A", isPlaying: true),
            deck2: deck(title: "Song B", isPlaying: true),
            crossfader: "50%"
        )
        // Deck 1 loads a new track
        let result = tracker.update(
            deck1: deck(title: "Song C", isPlaying: true),
            deck2: deck(title: "Song B", isPlaying: true),
            crossfader: "50%"
        )
        XCTAssertEqual(result, 2)
    }

    // MARK: - Mute handoff (line volume)

    func testMainDeckLineVolumeMuted_handoffToOther() {
        let tracker = MainDeckTracker()
        tracker.update(
            deck1: deck(isPlaying: true),
            deck2: deck(isPlaying: true),
            crossfader: "50%"
        )
        // Deck 1 line volume drops to 0
        let result = tracker.update(
            deck1: deck(isPlaying: true, lineVolume: "0%"),
            deck2: deck(isPlaying: true),
            crossfader: "50%"
        )
        XCTAssertEqual(result, 2)
    }

    // MARK: - Mute handoff (crossfader)

    func testCrossfaderFullyToDeck2_deck1HandsOff() {
        let tracker = MainDeckTracker()
        tracker.update(
            deck1: deck(isPlaying: true),
            deck2: deck(isPlaying: true),
            crossfader: "50%"
        )
        // Crossfader fully to deck 2
        let result = tracker.update(
            deck1: deck(isPlaying: true),
            deck2: deck(isPlaying: true),
            crossfader: "100%"
        )
        XCTAssertEqual(result, 2)
    }

    func testCrossfaderFullyToDeck1_deck2HandsOff() {
        let tracker = MainDeckTracker()
        // Deck 2 is main
        tracker.update(
            deck1: deck(),
            deck2: deck(isPlaying: true),
            crossfader: "50%"
        )
        // Crossfader fully to deck 1 — deck 2 is cut
        let result = tracker.update(
            deck1: deck(isPlaying: true),
            deck2: deck(isPlaying: true),
            crossfader: "0%"
        )
        XCTAssertEqual(result, 1)
    }

    // MARK: - Crossfader partial — no handoff

    func testCrossfaderPartial_noHandoff() {
        let tracker = MainDeckTracker()
        tracker.update(
            deck1: deck(isPlaying: true),
            deck2: deck(isPlaying: true),
            crossfader: "50%"
        )
        // Crossfader moves but not fully to either side
        let result = tracker.update(
            deck1: deck(isPlaying: true),
            deck2: deck(isPlaying: true),
            crossfader: "30%"
        )
        XCTAssertEqual(result, 1)
    }

    // MARK: - No valid target

    func testMainDeckPauses_otherAlsoNotPlaying_mainBecomesNil() {
        let tracker = MainDeckTracker()
        tracker.update(
            deck1: deck(isPlaying: true),
            deck2: deck(),
            crossfader: "50%"
        )
        // Deck 1 pauses, deck 2 not playing
        let result = tracker.update(
            deck1: deck(isPlaying: false),
            deck2: deck(),
            crossfader: "50%"
        )
        XCTAssertNil(result)
    }

    // MARK: - Recovery from nil

    func testRecoveryFromNil_deck2StartsPlaying() {
        let tracker = MainDeckTracker()
        // Both stopped
        tracker.update(deck1: deck(), deck2: deck(), crossfader: "50%")
        // Deck 2 starts
        let result = tracker.update(
            deck1: deck(),
            deck2: deck(isPlaying: true),
            crossfader: "50%"
        )
        XCTAssertEqual(result, 2)
    }

    // MARK: - No flip-flop on unmute

    func testMuteThenUnmute_staysHandedOff() {
        let tracker = MainDeckTracker()
        // Deck 1 is main, both playing
        tracker.update(
            deck1: deck(isPlaying: true),
            deck2: deck(isPlaying: true),
            crossfader: "50%"
        )
        // Deck 1 muted — hands off to deck 2
        tracker.update(
            deck1: deck(isPlaying: true, lineVolume: "0%"),
            deck2: deck(isPlaying: true),
            crossfader: "50%"
        )
        // Deck 1 unmuted — should stay on deck 2, no flip-flop
        let result = tracker.update(
            deck1: deck(isPlaying: true),
            deck2: deck(isPlaying: true),
            crossfader: "50%"
        )
        XCTAssertEqual(result, 2)
    }
}
