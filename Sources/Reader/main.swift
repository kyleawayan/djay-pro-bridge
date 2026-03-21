import DjayBridge
import Foundation

// MARK: - Parse arguments

var intervalMs: UInt32 = 50
let args = CommandLine.arguments
if let idx = args.firstIndex(of: "--interval"), idx + 1 < args.count,
   let ms = UInt32(args[idx + 1]) {
    intervalMs = ms
}

// MARK: - Find djay Pro and check permissions

guard let djay = findDjayPro() else { exit(1) }
guard checkAccessibilityPermission(djay.element) else { exit(1) }

printError("🎧 Polling djay Pro every \(intervalMs)ms... (Ctrl+C to stop)\n")

// MARK: - Poll loop

var lastDeck1Key = ""
var lastDeck2Key = ""

while true {
    let deck1 = getDeckInfo(app: djay.element, deckNumber: 1)
    let deck2 = getDeckInfo(app: djay.element, deckNumber: 2)

    let d1Key = deck1.key ?? "—"
    let d2Key = deck2.key ?? "—"

    if d1Key != lastDeck1Key || d2Key != lastDeck2Key {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print("[\(timestamp)]")
        print("  Deck 1: \(deck1.title ?? "—") by \(deck1.artist ?? "—") | Key: \(d1Key)")
        print("  Deck 2: \(deck2.title ?? "—") by \(deck2.artist ?? "—") | Key: \(d2Key)")
        print("")

        lastDeck1Key = d1Key
        lastDeck2Key = d2Key
    }

    usleep(intervalMs * 1000)
}
