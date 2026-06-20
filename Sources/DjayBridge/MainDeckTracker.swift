import Foundation

public class MainDeckTracker {
    public private(set) var mainDeck: Int? = nil
    private var previousTitle1: String? = nil
    private var previousTitle2: String? = nil

    public init() {}

    /// Call each poll cycle with current deck states and crossfader value.
    /// Returns the current main deck number (1 or 2), or nil.
    @discardableResult
    public func update(deck1: DeckInfo, deck2: DeckInfo, crossfader: String?) -> Int? {
        let deck1OnAir = isOnAir(deck: deck1, deckNumber: 1, crossfader: crossfader)
        let deck2OnAir = isOnAir(deck: deck2, deckNumber: 2, crossfader: crossfader)

        if let current = mainDeck {
            let currentDeck = current == 1 ? deck1 : deck2
            let currentOnAir = current == 1 ? deck1OnAir : deck2OnAir
            let currentPrevTitle = current == 1 ? previousTitle1 : previousTitle2

            var shouldHandoff = false

            // Handoff trigger: main deck paused
            if !currentDeck.isPlaying {
                shouldHandoff = true
            }

            // Handoff trigger: main deck loaded a new track
            if let prevTitle = currentPrevTitle, currentDeck.title != prevTitle {
                shouldHandoff = true
            }

            // Handoff trigger: main deck fully muted
            if !currentOnAir {
                shouldHandoff = true
            }

            if shouldHandoff {
                let other = current == 1 ? 2 : 1
                let otherDeck = other == 1 ? deck1 : deck2
                let otherOnAir = other == 1 ? deck1OnAir : deck2OnAir

                if otherDeck.isPlaying && otherOnAir {
                    mainDeck = other
                } else {
                    mainDeck = nil
                }
            }
        }

        // If no main deck, assign first playing + on-air deck
        if mainDeck == nil {
            if deck1.isPlaying && deck1OnAir {
                mainDeck = 1
            } else if deck2.isPlaying && deck2OnAir {
                mainDeck = 2
            }
        }

        previousTitle1 = deck1.title
        previousTitle2 = deck2.title

        return mainDeck
    }
}

// MARK: - Helpers

private func parsePercent(_ value: String?) -> Int? {
    guard let value = value else { return nil }
    let cleaned = value.replacingOccurrences(of: "%", with: "")
    return Int(cleaned)
}

private func isOnAir(deck: DeckInfo, deckNumber: Int, crossfader: String?) -> Bool {
    guard let lineVol = parsePercent(deck.lineVolume), lineVol > 0 else {
        return false
    }

    if let cf = parsePercent(crossfader) {
        // Crossfader at 0% = only Deck 1 audible
        // Crossfader at 100% = only Deck 2 audible
        if cf == 0 && deckNumber == 2 { return false }
        if cf == 100 && deckNumber == 1 { return false }
    }

    return true
}
