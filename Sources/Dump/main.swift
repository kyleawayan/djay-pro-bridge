import DjayBridge
import ApplicationServices
import Foundation
import Cocoa

// MARK: - Full-tree AX prober
//
// Walks djay Pro's entire accessibility tree (all windows + any open menus),
// printing role / subrole / title / description / value / identifier / selected
// state / supported actions per node. This is the verification tool for the
// playlist-sorter feature: it answers "does the song list expose AXSelectedRows,
// does a row advertise AXShowMenu, are context-menu items AXPress-able".
//
// Usage:
//   swift run Dump                       full tree, immediately
//   swift run Dump --delay 6             wait 6s, then snapshot (open a context
//                                        menu in djay during the countdown)
//   swift run Dump --delay 6 --menus     after the delay, print ONLY open menus
//   swift run Dump --breadth 6           cap rows printed per container (default 12)
//   swift run Dump --max-depth 30        recursion cap (default 40)

var delay: TimeInterval = 0
var maxDepth = 40
var breadthCap = 12
var menusOnly = false
var triggerMenu = false
var probeAdd = false
var probeDelete = false

do {
    let argv = CommandLine.arguments
    var i = 1
    while i < argv.count {
        switch argv[i] {
        case "--delay":        i += 1; delay = Double(argv[safe: i] ?? "0") ?? 0
        case "--max-depth":    i += 1; maxDepth = Int(argv[safe: i] ?? "40") ?? 40
        case "--breadth":      i += 1; breadthCap = Int(argv[safe: i] ?? "12") ?? 12
        case "--menus":        menusOnly = true
        case "--trigger-menu": triggerMenu = true
        case "--probe-add":    probeAdd = true
        case "--probe-delete": probeDelete = true
        default: break
        }
        i += 1
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Local AX helpers (beyond the shared ones in DjayBridge)

func axActions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success,
          let arr = names as? [String] else { return [] }
    return arr
}

func axElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
    var v: AnyObject?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
          let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

func axElements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
    getAttr(el, attr) as? [AXUIElement] ?? []
}

func axBool(_ el: AXUIElement, _ attr: String) -> Bool {
    ((getAttr(el, attr) as? NSNumber)?.boolValue) ?? false
}

func findFirst(_ el: AXUIElement, depth: Int = 0, where pred: (AXUIElement) -> Bool) -> AXUIElement? {
    if pred(el) { return el }
    guard depth < maxDepth else { return nil }
    for c in getChildren(el) {
        if let f = findFirst(c, depth: depth + 1, where: pred) { return f }
    }
    return nil
}

func quote(_ s: String) -> String {
    let one = s.replacingOccurrences(of: "\n", with: "⏎")
    let clipped = one.count > 70 ? String(one.prefix(70)) + "…" : one
    return "\"\(clipped)\""
}

func summary(_ el: AXUIElement) -> String {
    var parts = [getRole(el) ?? "?"]
    if let s = getAttr(el, "AXSubrole") as? String { parts.append("sub=\(s)") }
    if let t = getTitle(el), !t.isEmpty { parts.append("title=\(quote(t))") }
    if let d = getLabel(el), !d.isEmpty { parts.append("desc=\(quote(d))") }
    if let v = getValue(el), !v.isEmpty { parts.append("val=\(quote(v))") }
    if let id = getAttr(el, "AXIdentifier") as? String, !id.isEmpty { parts.append("id=\(id)") }
    if axBool(el, "AXSelected") { parts.append("SELECTED") }
    let acts = axActions(el)
    if !acts.isEmpty { parts.append("actions=[\(acts.joined(separator: ","))]") }
    return parts.joined(separator: " ")
}

// MARK: - Walk

var out = ""

func walk(_ el: AXUIElement, depth: Int) {
    let indent = String(repeating: "  ", count: depth)
    out += indent + summary(el) + "\n"
    guard depth < maxDepth else { return }

    let role = getRole(el)
    let children = getChildren(el)

    // Always surface selected rows/children explicitly — the highlighted track
    // may sit far beyond the breadth cap.
    let selected = axElements(el, "AXSelectedRows") + axElements(el, "AXSelectedChildren")
    if !selected.isEmpty {
        out += indent + "  ↳ SELECTED (\(selected.count)):\n"
        for s in selected { walk(s, depth: depth + 2) }
    }

    // Menus are small and the whole point — never cap them.
    let isMenu = role == "AXMenu" || role == "AXMenuBar"
    let cap = isMenu ? children.count : min(children.count, breadthCap)
    for (idx, child) in children.enumerated() {
        if idx >= cap {
            out += indent + "  … (\(children.count - cap) more of \(children.count))\n"
            break
        }
        walk(child, depth: depth + 1)
    }
}

func collectMenus(_ el: AXUIElement, depth: Int = 0, into acc: inout [AXUIElement]) {
    let role = getRole(el)
    if role == "AXMenuBar" { return }   // skip the always-present menu-bar dropdowns
    if role == "AXMenu" { acc.append(el); return }
    guard depth < maxDepth else { return }
    for child in getChildren(el) { collectMenus(child, depth: depth + 1, into: &acc) }
}

// MARK: - Run

guard let djay = findDjayPro() else { exit(1) }
guard checkAccessibilityPermission(djay.element) else { exit(1) }

if delay > 0 {
    printError("⏳ \(Int(delay))s — switch to djay and open a context menu (right-click a track), leave it open…")
    Thread.sleep(forTimeInterval: delay)
}

// Focused element (for the keyboard-gate text-field check).
out += "=== FOCUSED ELEMENT ===\n"
if let f = axElement(djay.element, kAXFocusedUIElementAttribute) {
    out += summary(f) + "\n"
} else {
    out += "(none / not reported)\n"
}
out += "\n"

func submenuItems(_ item: AXUIElement) -> [AXUIElement] {
    guard let sub = getChildren(item).first(where: { getRole($0) == "AXMenu" }) else { return [] }
    return getChildren(sub)
}
func titles(_ els: [AXUIElement]) -> String {
    els.map { getTitle($0) ?? "(untitled)" }.joined(separator: " | ")
}

if probeDelete {
    func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        let d = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true); d?.flags = flags
        let u = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false); u?.flags = flags
        d?.post(tap: .cghidEventTap); u?.post(tap: .cghidEventTap)
    }

    NSRunningApplication(processIdentifier: djay.pid)?.activate(options: [])
    Thread.sleep(forTimeInterval: 0.3)

    // SAFETY: only proceed if the song table is focused, so Cmd+Delete can't
    // delete a playlist or anything else.
    guard let f = getFocusedElement(djay.element),
          getRole(f) == "AXTable", getTitle(f) == "Playlist" else {
        printError("❌ song table not focused — aborting (won't risk deleting the wrong thing)")
        exit(1)
    }

    printError("→ Cmd+Delete (will CANCEL — nothing deleted)…")
    postKey(0x33, flags: .maskCommand)   // Cmd+Delete
    Thread.sleep(forTimeInterval: 0.7)

    let sheet = findFirst(djay.element) { getRole($0) == "AXSheet" }
    let dialog = findFirst(djay.element) {
        let s = getSubrole($0); return s == "AXDialog" || s == "AXSystemDialog"
    }
    out += "=== TOP-LEVEL WINDOWS ===\n"
    for w in getChildren(djay.element) {
        out += "  \(getRole(w) ?? "?") sub=\(getSubrole(w) ?? "-") title=\"\(getTitle(w) ?? "")\"\n"
    }
    if let target = sheet ?? dialog {
        out += "\n=== DIALOG/SHEET ===\n"
        walk(target, depth: 0)
        if let def = getDefaultButton(target) {
            out += "\nDEFAULT BUTTON: \(summary(def))\n"
        } else {
            out += "\n(no AXDefaultButton attribute on the dialog)\n"
        }
    } else {
        out += "\n(no sheet/dialog found — Cmd+Delete may not have prompted)\n"
    }
    print(out)

    // Abort non-destructively: press Cancel, else Escape.
    if let cancel = findFirst(djay.element, where: { getRole($0) == "AXButton" && getTitle($0) == "Cancel" }) {
        performAction(cancel, kAXPressAction)
        printError("✅ pressed Cancel — nothing deleted")
    } else {
        postKey(0x35, flags: [])  // Escape
        printError("✅ sent Escape — nothing deleted")
    }
    exit(0)
}

if probeAdd {
    NSRunningApplication(processIdentifier: djay.pid)?.activate(options: [])
    Thread.sleep(forTimeInterval: 0.3)
    let table = findFirst(djay.element) { getRole($0) == "AXTable" && getTitle($0) == "Playlist" }
    guard let table else { printError("no Playlist table"); exit(1) }

    DispatchQueue.global().async { performAction(table, kAXShowMenuAction) }
    Thread.sleep(forTimeInterval: 0.6)
    var menus: [AXUIElement] = []
    collectMenus(djay.element, into: &menus)
    guard let menu = menus.first else { printError("no context menu"); exit(1) }

    guard let addItem = getChildren(menu).first(where: { getTitle($0) == "Add to Playlist" }) else {
        printError("no 'Add to Playlist' item"); exit(1)
    }

    out += "BEFORE press — Add to Playlist submenu: [\(titles(submenuItems(addItem)))]\n"

    // Try AXPress to open/expand the submenu.
    printError("→ AXPress 'Add to Playlist'…")
    DispatchQueue.global().async { performAction(addItem, kAXPressAction) }
    Thread.sleep(forTimeInterval: 0.7)
    out += "AFTER AXPress — Add to Playlist submenu: [\(titles(submenuItems(addItem)))]\n"

    // Re-read the menu fresh too, in case the element handle is stale.
    var menus2: [AXUIElement] = []
    collectMenus(djay.element, into: &menus2)
    if let m2 = menus2.first,
       let add2 = getChildren(m2).first(where: { getTitle($0) == "Add to Playlist" }) {
        out += "AFTER AXPress (fresh handle): [\(titles(submenuItems(add2)))]\n"
    }
    out += "\n=== full menu tree after press ===\n"
    for m in menus2 { walk(m, depth: 0) }

    for m in menus2 { performAction(m, kAXCancelAction) }
    print(out)
    exit(0)
}

if triggerMenu {
    // Bring djay to front so the context menu actually presents.
    NSRunningApplication(processIdentifier: djay.pid)?.activate(options: [])
    Thread.sleep(forTimeInterval: 0.3)

    let table = findFirst(djay.element) { getRole($0) == "AXTable" && getTitle($0) == "Playlist" }
    let selectedRow = table.flatMap { axElements($0, "AXSelectedRows").first }

    func tryTrigger(_ target: AXUIElement, label: String) -> [AXUIElement] {
        printError("→ AXShowMenu on \(label) (advertised: \(axActions(target).contains(kAXShowMenuAction)))…")
        // Perform on a background thread: AXShowMenu can block in the target's
        // modal menu-tracking loop, so we read the tree from the main thread
        // while the menu is up.
        DispatchQueue.global().async { performAction(target, kAXShowMenuAction) }
        Thread.sleep(forTimeInterval: 0.6)
        var menus: [AXUIElement] = []
        collectMenus(djay.element, into: &menus)
        if !menus.isEmpty { out += "(opened via: \(label))\n" }
        return menus
    }

    var menus: [AXUIElement] = []
    if let t = table { menus = tryTrigger(t, label: "Playlist table") }
    if menus.isEmpty, let row = selectedRow { menus = tryTrigger(row, label: "selected row") }

    out += "=== MENUS AFTER AXShowMenu (\(menus.count)) ===\n"
    if menus.isEmpty {
        out += "(none — AXShowMenu did not surface an AX menu)\n"
    }
    for m in menus { walk(m, depth: 0) }
    // Close any menu we opened so djay is left clean.
    for m in menus { performAction(m, kAXCancelAction) }
} else if menusOnly {
    var menus: [AXUIElement] = []
    collectMenus(djay.element, into: &menus)
    out += "=== OPEN MENUS (\(menus.count)) ===\n"
    for m in menus { walk(m, depth: 0) }
} else {
    out += "=== TREE ===\n"
    walk(djay.element, depth: 0)
}

print(out)
