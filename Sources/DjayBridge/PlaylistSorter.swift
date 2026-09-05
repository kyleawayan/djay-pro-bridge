import Cocoa
import ApplicationServices
import Foundation

// MARK: - djay Pro playlist sorter
//
// Drives djay Pro's own right-click context menu via the Accessibility API to
// file the selected track into a playlist and (optionally) remove it from the
// current one. Verified mechanics (see Dump --trigger-menu / --probe-add):
//
//   • The song list is `AXTable title="Playlist"` and advertises AXShowMenu.
//   • AXShowMenu on that table opens the track context menu (a top-level AXMenu,
//     NOT under the menu bar). Its items expose AXPress/AXPick.
//   • "Add to Playlist" has a LAZY submenu: it lists only "New Playlist" until
//     the parent item is AXPress'd, after which all playlists appear, each
//     titled "[N] …".
//   • "Remove from Playlist" is present only in a user-playlist view (guard).
//   • "Show in Playlist" submenu lists the playlists already containing the track.
//
// AXShowMenu / AXPress on a submenu parent block the calling thread inside djay's
// modal menu-tracking loop, so those are dispatched to a background queue while
// the main flow polls the tree and drives the next step. Pressing a leaf item
// dismisses the menu and unblocks those background calls.

// MARK: - Virtual key codes (avoid importing Carbon)

private let kVKDelete: CGKeyCode = 0x33

// MARK: - Outcome

public enum SortOutcome {
    case added(track: String, playlist: String, removed: Bool)
    case alreadyInPlaylist(track: String, playlist: String)   // djay popped its Add/Skip/Cancel dialog — halted for the user
    case noPlaylistForSlot(Int)
    case noSelection
    case noMenu
    case failed(String)
}

public enum RemoveOutcome {
    case removed(track: String)
    case notRemovable(track: String)   // current view offers no "Remove from Playlist" (e.g. a smart playlist)
    case noSelection
    case noMenu
}

// MARK: - Tree search

func findFirst(in el: AXUIElement, maxDepth: Int = 18, depth: Int = 0,
               where pred: (AXUIElement) -> Bool) -> AXUIElement? {
    if pred(el) { return el }
    guard depth < maxDepth else { return nil }
    for child in getChildren(el) {
        if let found = findFirst(in: child, maxDepth: maxDepth, depth: depth + 1, where: pred) {
            return found
        }
    }
    return nil
}

func allStaticTextValues(_ el: AXUIElement, depth: Int = 0) -> [String] {
    var out: [String] = []
    if getRole(el) == "AXStaticText", let v = getValue(el), !v.isEmpty { out.append(v) }
    guard depth < 6 else { return out }
    for child in getChildren(el) { out += allStaticTextValues(child, depth: depth + 1) }
    return out
}

func firstStaticTextValue(_ el: AXUIElement) -> String? {
    allStaticTextValues(el).first
}

// MARK: - Library table + selection

public func findSongTable(_ app: AXUIElement) -> AXUIElement? {
    findFirst(in: app) { getRole($0) == "AXTable" && getTitle($0) == "Playlist" }
}

public func getSelectedTrackRow(_ app: AXUIElement) -> AXUIElement? {
    guard let table = findSongTable(app) else { return nil }
    return getSelectedRows(table).first
}

/// Best-effort human label for the selected track (title), for logging only.
public func selectedTrackLabel(_ app: AXUIElement) -> String? {
    guard let row = getSelectedTrackRow(app) else { return nil }
    // Row cells in order: playing-icon, number, artwork, TITLE, artist, bpm, key, …
    // The first "wordy" value (has a letter, length > 2) is the title.
    let wordy = allStaticTextValues(row).filter {
        $0.count > 2 && $0.rangeOfCharacter(from: .letters) != nil
    }
    return wordy.first
}

// MARK: - Current playlist (for the inbox gate + remove guard naming)

/// Name of the currently-viewed source/playlist, from the sidebar selection,
/// falling back to the playlist header beside the "N Songs" popup.
public func currentPlaylistName(_ app: AXUIElement) -> String? {
    if let outline = findFirst(in: app, where: { getRole($0) == "AXOutline" && getTitle($0) == "Playlists" }),
       let selected = getSelectedRows(outline).first,
       let name = firstStaticTextValue(selected) {
        return name
    }
    // Fallback: among the siblings of the "N Songs" pop-up, the playlist name is
    // the static text that is neither the song count nor the "10h 14m" duration.
    if let songsPopup = findFirst(in: app, where: {
        getRole($0) == "AXPopUpButton" &&
        (getTitle($0)?.range(of: #"^\d+ Songs$"#, options: .regularExpression) != nil)
    }), let parent = getElementAttr(songsPopup, kAXParentAttribute) {
        for child in getChildren(parent) where getRole(child) == "AXStaticText" {
            guard let v = getValue(child), !v.isEmpty else { continue }
            if v.range(of: #"^\d+h(\s+\d+m)?$"#, options: .regularExpression) != nil { continue }
            if v.range(of: #"^\d+ Songs$"#, options: .regularExpression) != nil { continue }
            return v
        }
    }
    return nil
}

// MARK: - Context menu

/// The track context menu opens as a DIRECT CHILD of the song table (verified
/// ancestor chain: AXMenu < AXTable). Looking for it there is O(rows) with no
/// deep tree walk — and avoids the trap of pruning the table to stay cheap (which
/// would prune the menu itself, since it lives under the table).
func contextMenu(of table: AXUIElement) -> AXUIElement? {
    getChildren(table).first { getRole($0) == "AXMenu" }
}

func waitForContextMenu(of table: AXUIElement, timeoutMs: Int) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    repeat {
        if let menu = contextMenu(of: table) { return menu }
        Thread.sleep(forTimeInterval: 0.03)
    } while Date() < deadline
    return nil
}

func menuItem(_ menu: AXUIElement, titled title: String) -> AXUIElement? {
    getChildren(menu).first { getTitle($0) == title }
}

/// A freshly-shown context menu is an empty shell for a beat; its items populate
/// shortly after. Poll the menu's children for the titled item.
func waitForMenuItem(_ menu: AXUIElement, titled title: String, timeoutMs: Int) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    repeat {
        if let item = menuItem(menu, titled: title) { return item }
        Thread.sleep(forTimeInterval: 0.03)
    } while Date() < deadline
    return nil
}

func submenu(of item: AXUIElement) -> AXUIElement? {
    getChildren(item).first { getRole($0) == "AXMenu" }
}

/// Open the track context menu by performing AXShowMenu on the song table.
/// Runs the (blocking) action on a background queue and polls for the menu.
func openContextMenu(_ app: AXUIElement, timeoutMs: Int = 1500) -> AXUIElement? {
    guard let table = findSongTable(app) else { return nil }
    // djay must be frontmost for the context menu to present.
    ensureFrontmost(pidOf(app))
    dismissStale(app, table: table)   // clear any leftover menu/dialog
    DispatchQueue.global().async { performAction(table, kAXShowMenuAction) }
    if let menu = waitForContextMenu(of: table, timeoutMs: timeoutMs) { return menu }
    // Timed out — cancel a menu that may have opened late so it doesn't block the next run.
    if let late = contextMenu(of: table) { performAction(late, kAXCancelAction) }
    return nil
}

func closeMenu(_ menu: AXUIElement) {
    performAction(menu, kAXCancelAction)
}

/// Clear leftover state from a prior aborted run: an open context menu, or a
/// confirm dialog (pressed CANCEL — never confirm a delete we didn't initiate).
/// A lingering modal otherwise blocks AXShowMenu on the next run.
func dismissStale(_ app: AXUIElement, table: AXUIElement) {
    if let menu = contextMenu(of: table) { performAction(menu, kAXCancelAction) }
    for w in getChildren(app) where getSubrole(w) == "AXDialog" || getRole(w) == "AXSheet" {
        if let cancel = findFirst(in: w, where: { getRole($0) == "AXButton" && getTitle($0) == "Cancel" }) {
            performAction(cancel, kAXPressAction)
        }
    }
}

// MARK: - Add to playlist

/// Press "Add to Playlist" → its lazy submenu → the "[slot] " entry.
/// Returns the matched playlist title, or nil if no "[slot] " playlist exists.
/// Leaves the menu CLOSED on success (pressing the leaf dismisses it).
func pressAddToPlaylist(item addItem: AXUIElement, slot: Int) -> String? {
    // Press the parent to populate + open its lazy submenu (blocks in modal loop).
    DispatchQueue.global().async { performAction(addItem, kAXPressAction) }

    let prefix = "[\(slot)] "
    let deadline = Date().addingTimeInterval(1.5)
    repeat {
        if let sub = submenu(of: addItem),
           let match = getChildren(sub).first(where: { ($0.title ?? "").hasPrefix(prefix) }) {
            let name = match.title ?? prefix
            performAction(match, kAXPressAction)   // dismisses the menu, files the track
            return name
        }
        Thread.sleep(forTimeInterval: 0.04)
    } while Date() < deadline
    return nil
}

// MARK: - Remove from current playlist (Cmd+Delete + confirm)

func pidOf(_ el: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    return pid
}

func activateDjay(_ pid: pid_t) {
    NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
}

/// Bring djay frontmost and block until it actually is (or timeout). Near-instant
/// when djay is already frontmost (the normal keyboard-flow case).
func ensureFrontmost(_ pid: pid_t, timeoutMs: Int = 600) {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return }
    activateDjay(pid)
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.03)
    }
    Thread.sleep(forTimeInterval: 0.05)   // brief settle after focus change
}

func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
    down?.flags = flags
    let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
    up?.flags = flags
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

/// A modal alert/sheet attached to the app (the remove-confirm, or the
/// "already in playlist" Add/Skip/Cancel alert).
func findDialog(_ app: AXUIElement) -> AXUIElement? {
    for window in getChildren(app) {
        let sub = getSubrole(window)
        if getRole(window) == "AXSheet" || sub == "AXDialog" || sub == "AXSystemDialog" { return window }
        if let sheet = findFirst(in: window, maxDepth: 4, where: { getRole($0) == "AXSheet" }) { return sheet }
    }
    return nil
}

func waitForDialog(_ app: AXUIElement, timeoutMs: Int) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    repeat {
        if let d = findDialog(app) { return d }
        Thread.sleep(forTimeInterval: 0.03)
    } while Date() < deadline
    return nil
}

func pressDialogButton(_ dialog: AXUIElement, titledAnyOf titles: [String]) -> Bool {
    guard let btn = findFirst(in: dialog, where: {
        getRole($0) == "AXButton" && titles.contains(getTitle($0) ?? "")
    }) else { return false }
    return performAction(btn, kAXPressAction)
}

/// Confirm djay's remove-from-playlist alert by pressing its "Remove Item" button.
/// Matches removal verbs ONLY — never a generic default button — so an unexpected
/// sheet (notably the duplicate Add/Skip/Cancel alert, whose default is "Add") is
/// left completely untouched.
func confirmRemoveDialog(_ app: AXUIElement, timeoutMs: Int) -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    repeat {
        if let dialog = findDialog(app),
           pressDialogButton(dialog, titledAnyOf: ["Remove Item", "Remove", "Delete"]) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.03)
    } while Date() < deadline
    return false
}

/// Remove the selected track from the current playlist via Cmd+Delete, then
/// accept djay's confirmation dialog. Returns true if a dialog was confirmed.
@discardableResult
func removeSelectedTrackFromCurrentPlaylist(_ app: AXUIElement, pid: pid_t) -> Bool {
    let table = findSongTable(app)
    // Wait for the context menu to fully close before sending the keystroke.
    if let table {
        let deadline = Date().addingTimeInterval(0.8)
        while contextMenu(of: table) != nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.03) }
    }
    ensureFrontmost(pid)
    // Cmd+Delete acts on the focused list, so make sure the song table has focus
    // (the menu interaction moves focus off it, which silently no-ops the delete).
    if let table { AXUIElementSetAttributeValue(table, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
    Thread.sleep(forTimeInterval: 0.05)
    postKey(kVKDelete, flags: .maskCommand)
    // Accept djay's confirm dialog by pressing its "Remove Item" button.
    return confirmRemoveDialog(app, timeoutMs: 1500)
}

// MARK: - Remove-only (vim "dd", no filing into [N])

/// Remove the selected track from the current playlist with no add step.
/// Guarded: presses the context menu's "Remove from Playlist" item directly, so
/// it can only ever remove from a playlist — it never falls through to Cmd+Delete
/// and a "Delete from library" dialog. The item is absent in views that can't be
/// removed from (smart playlists, the full library), which reports .notRemovable.
public func removeSelectedFromCurrentPlaylist(_ app: AXUIElement, pid: pid_t) -> RemoveOutcome {
    guard getSelectedTrackRow(app) != nil else { return .noSelection }
    let track = selectedTrackLabel(app) ?? "track"

    guard let menu = openContextMenu(app) else { return .noMenu }
    guard let item = waitForMenuItem(menu, titled: "Remove from Playlist", timeoutMs: 1200) else {
        closeMenu(menu)
        return .notRemovable(track: track)
    }
    performAction(item, kAXPressAction)   // dismisses the menu, removes the track
    // Some views pop a confirm dialog for the removal; accept it if it shows.
    _ = confirmRemoveDialog(app, timeoutMs: 1500)
    // Pressing the item moved focus off the table; refocus so j/k keep working.
    if let table = findSongTable(app) {
        AXUIElementSetAttributeValue(table, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }
    return .removed(track: track)
}

// MARK: - Load on Deck 1

/// Load the selected track onto Deck 1 via the context menu's "Load on Deck 1"
/// item, then refocus the song table so j/k navigation keeps working (pressing
/// the item moves focus off the table, same as the remove flow).
@discardableResult
public func loadSelectedTrackOnDeck1(_ app: AXUIElement, pid: pid_t) -> Bool {
    guard getSelectedTrackRow(app) != nil else { return false }
    guard let menu = openContextMenu(app) else { return false }
    guard let item = waitForMenuItem(menu, titled: "Load on Deck 1", timeoutMs: 1200) else {
        closeMenu(menu)
        return false
    }
    let ok = performAction(item, kAXPressAction)   // dismisses the menu, loads the deck
    if let table = findSongTable(app) {
        AXUIElementSetAttributeValue(table, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }
    return ok
}

// MARK: - Bonus: playlists already containing the track

public func playlistsContainingSelectedTrack(_ app: AXUIElement) -> [String] {
    guard let menu = openContextMenu(app) else { return [] }
    defer { closeMenu(menu) }
    guard let showItem = waitForMenuItem(menu, titled: "Show in Playlist", timeoutMs: 1200) else { return [] }
    // The submenu is lazy: press the parent to populate/open it before reading.
    DispatchQueue.global().async { performAction(showItem, kAXPressAction) }
    let deadline = Date().addingTimeInterval(1.2)
    repeat {
        if let sub = submenu(of: showItem) {
            let names = getChildren(sub).compactMap { $0.title }.filter { !$0.isEmpty }
            if !names.isEmpty { return names }
        }
        Thread.sleep(forTimeInterval: 0.04)
    } while Date() < deadline
    return []
}

// MARK: - Compose

/// Add the selected track to playlist [slot], then remove it from the current
/// playlist (guarded: only if the menu offers "Remove from Playlist").
public func sortSelectedTrack(_ app: AXUIElement, pid: pid_t, slot: Int) -> SortOutcome {
    guard getSelectedTrackRow(app) != nil else { return .noSelection }
    let track = selectedTrackLabel(app) ?? "track"

    guard let menu = openContextMenu(app) else { return .noMenu }

    // Wait for the menu to populate (the freshly-shown menu is an empty shell).
    guard let addItem = waitForMenuItem(menu, titled: "Add to Playlist", timeoutMs: 1200) else {
        closeMenu(menu)
        return .noMenu
    }
    // Guard signal: removal is only safe when this is a user playlist.
    let canRemove = menuItem(menu, titled: "Remove from Playlist") != nil

    guard let playlist = pressAddToPlaylist(item: addItem, slot: slot) else {
        closeMenu(menu)
        return .noPlaylistForSlot(slot)
    }

    // If the track is already in [N], djay pops an Add / Skip / Cancel alert
    // (an AXSheet) instead of adding silently. Stop everything and leave it open
    // so the user decides — do NOT auto-confirm, do NOT remove from the inbox.
    if waitForDialog(app, timeoutMs: 800) != nil {
        return .alreadyInPlaylist(track: track, playlist: playlist)
    }

    // Clean add (no dialog). Remove from the current playlist if safe.
    if canRemove {
        let removed = removeSelectedTrackFromCurrentPlaylist(app, pid: pid)
        // Safety net: if the dup sheet slipped past the window above, the remove
        // was blocked by the modal and confirmRemoveDialog left it untouched —
        // report the halt rather than a bogus "added/removed".
        if !removed, findDialog(app) != nil {
            return .alreadyInPlaylist(track: track, playlist: playlist)
        }
        return .added(track: track, playlist: playlist, removed: removed)
    } else {
        return .added(track: track, playlist: playlist, removed: false)
    }
}

// MARK: - AXUIElement convenience

extension AXUIElement {
    var title: String? { getTitle(self) }
}
