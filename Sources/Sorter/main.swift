import DjayBridge
import Cocoa
import Foundation

// MARK: - djay Pro vim-flow library organizer
//
// Standalone command (independent of the Reader TUI / MIDI bridge). Intercepts
// bare keys while djay is frontmost (via CGEventTap — see KeyboardTrigger):
//
//   1 2 3 5 8  file the selected track into playlist "[N] …" + remove from current
//   d d        remove the selected track from the current playlist (no filing)
//   j / k      down / up the track list        h / l   beat jump back / forward
//   enter      load selected track on Deck 1    m       show playlist membership
//   esc        press OK on djay's "Could not load track" alert

// MARK: - Args

var onceSlot: Int?           // --once N : run one sort on the current selection and exit
var onceMembership = false   // --membership : print current track's playlists and exit
do {
    let argv = CommandLine.arguments
    var i = 1
    while i < argv.count {
        switch argv[i] {
        case "--once":       i += 1; if i < argv.count { onceSlot = Int(argv[i]) }
        case "--membership": onceMembership = true
        default: break
        }
        i += 1
    }
}

// MARK: - Setup

guard let djay = findDjayPro() else { exit(1) }
guard checkAccessibilityPermission(djay.element) else { exit(1) }
let app = djay.element
let pid = djay.pid

let clock: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
}()
func stamp() -> String { "[\(clock.string(from: Date()))]" }

func logOutcome(_ o: SortOutcome, slot: Int) {
    switch o {
    case .added(let track, let playlist, let removed):
        // `removed` = a remove-confirm dialog was pressed. djay can remove without
        // prompting, so a false here means "unconfirmed", not "definitely not removed".
        let tail = removed ? "removed from current playlist ✓"
                           : "removal unconfirmed (no confirm dialog seen)"
        printError("\(stamp()) \"\(track)\" → added \(playlist) · \(tail)")
    case .alreadyInPlaylist(let track, let playlist):
        printError("\(stamp()) ⏸ \"\(track)\" already in \(playlist) — halted; choose Add/Skip/Cancel in djay yourself (not removed)")
    case .noPlaylistForSlot(let n):
        printError("\(stamp()) ⚠ no playlist \"[\(n)] …\" — left in place")
    case .noSelection:
        printError("\(stamp()) ⚠ press \(slot): no track selected")
    case .noMenu:
        printError("\(stamp()) ⚠ press \(slot): could not open djay's context menu")
    case .failed(let m):
        printError("\(stamp()) ⚠ \(m)")
    }
}

// MARK: - One-shot test modes (no event tap)

if onceMembership {
    let track = selectedTrackLabel(app) ?? "track"
    let names = playlistsContainingSelectedTrack(app)
    printError("\(stamp()) \"\(track)\" → in: \(names.isEmpty ? "(none)" : names.joined(separator: ", "))")
    exit(0)
}
if let slot = onceSlot {
    printError("\(stamp()) one-shot sort: slot \(slot) on current selection")
    let t0 = Date()
    let outcome = sortSelectedTrack(app, pid: pid, slot: slot)
    logOutcome(outcome, slot: slot)
    printError("  (took \(String(format: "%.2f", Date().timeIntervalSince(t0)))s)")
    exit(0)
}

// MARK: - Trigger
//
// The CGEventTap needs a run loop, so run as a faceless agent.

let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.accessory)

func showMembership() {
    let track = selectedTrackLabel(app) ?? "track"
    let names = playlistsContainingSelectedTrack(app)
    printError("\(stamp()) \"\(track)\" → in: \(names.isEmpty ? "(none)" : names.joined(separator: ", "))")
}

let trigger = KeyboardTrigger(pid: pid) { action in
    switch action {
    case .sort(let slot):
        let outcome = sortSelectedTrack(app, pid: pid, slot: slot)
        logOutcome(outcome, slot: slot)
    case .removeFromPlaylist:
        switch removeSelectedFromCurrentPlaylist(app, pid: pid) {
        case .removed(let track):
            printError("\(stamp()) \"\(track)\" → removed from current playlist ✓")
        case .notRemovable(let track):
            printError("\(stamp()) ⚠ dd \"\(track)\": current view has no 'Remove from Playlist'")
        case .noSelection:
            printError("\(stamp()) ⚠ dd: no track selected")
        case .noMenu:
            printError("\(stamp()) ⚠ dd: could not open djay's context menu")
        }
    case .dismissAlert:
        // Log only when an alert was actually dismissed — Escape fires this on
        // every press, and a no-op shouldn't spam the console.
        if dismissAlertOK(app) {
            printError("\(stamp()) esc → dismissed alert (OK)")
        }
    case .load:
        if loadSelectedTrackOnDeck1(app, pid: pid) {
            printError("\(stamp()) ⏵ loaded on Deck 1")
        } else {
            printError("\(stamp()) ⚠ could not load on Deck 1")
        }
    case .membership:
        showMembership()
    case .navDown, .navUp, .beatBack, .beatForward:
        break   // pure key emulation, handled inside KeyboardTrigger
    }
}

guard trigger.start() else { exit(1) }

printError("Destinations mapped by \"[N] \" playlist-name prefix.")
printError("Ready. djay frontmost:  1 2 3 5 8 = sort · dd = remove · j/k = up/down · enter = load Deck 1 · h/l = beat jump · m = membership · esc = dismiss alert.")

nsApp.run()
