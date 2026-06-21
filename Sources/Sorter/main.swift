import DjayBridge
import Cocoa
import Foundation

// MARK: - djay Pro one-key playlist sorter
//
// Standalone command (independent of the Reader TUI / MIDI bridge). While viewing
// the inbox playlist, press 1–8 to file the highlighted track into the playlist
// whose name starts with "[N] " and remove it from the inbox. Press ` to print
// which playlists the highlighted track already belongs to.
//
// The inbox is any playlist whose name starts with "!" (it sorts to the top) —
// same convention idea as the "[N] " destination prefixes. Nothing
// playlist-specific is baked into this tool.

// MARK: - Args

let inboxPrefix = "!"
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
        let tail = removed ? "removed from current playlist ✓"
                           : "⚠ added but NOT removed (no 'Remove from Playlist' in menu)"
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
// Carbon hotkeys need an application event loop, so run as a faceless agent.

let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.accessory)

let trigger = KeyboardTrigger(
    app: app, pid: pid, inboxPrefix: inboxPrefix,
    onSlot: { slot in
        let outcome = sortSelectedTrack(app, pid: pid, slot: slot)
        logOutcome(outcome, slot: slot)
    },
    onMembership: {
        let track = selectedTrackLabel(app) ?? "track"
        let names = playlistsContainingSelectedTrack(app)
        printError("\(stamp()) \"\(track)\" → in: \(names.isEmpty ? "(none)" : names.joined(separator: ", "))")
    }
)

guard trigger.start() else { exit(1) }

printError("Destinations mapped by \"[N] \" name prefix. Inbox = any playlist starting with \"\(inboxPrefix)\".")
printError("Ready. In the inbox, highlight a track and press F13–F17 (→ 1,2,3,5,8).  F18 = show membership.")

nsApp.run()
