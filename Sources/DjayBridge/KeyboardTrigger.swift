import Cocoa
import ApplicationServices
import Foundation

// MARK: - Inbox-gated global keyboard trigger
//
// A CGEventTap intercepts number keys 1–8 (and backtick for membership) but only
// SWALLOWS + acts on them when:
//   1. djay Pro is frontmost,
//   2. the current playlist == the configured inbox (cached by a 4 Hz poll),
//   3. the focused element is the song table (proxy for "a track row is focused
//      and we're not typing in the search/rename field").
// Otherwise the key passes through untouched, so digits type normally everywhere
// else — including djay's own search box.
//
// The tap callback stays cheap: it reads a cached inbox flag + one focused-element
// attribute, never walks the tree. The heavy sort work is dispatched to a serial
// queue so menu operations can't interleave and the run loop never stalls.

private let kVKGrave: CGKeyCode = 0x32   // backtick `

public final class KeyboardTrigger {
    public enum Modifier: String { case none, ctrl, alt }

    private let app: AXUIElement
    private let pid: pid_t
    private let inboxPrefix: String   // the inbox is any playlist whose name starts with this (e.g. "!")
    private let modifier: Modifier
    private let onSlot: (Int) -> Void
    private let onMembership: () -> Void

    private let lock = NSLock()
    private var cachedInbox = false
    private var cachedName: String?
    private var lastActive: Bool?

    private let workQueue = DispatchQueue(label: "playlist-sort")
    private var pollTimer: DispatchSourceTimer?
    private var eventTap: CFMachPort?

    // 1-8 → ANSI digit keycodes (non-contiguous).
    private static let slotKeycodes: [CGKeyCode: Int] = [
        0x12: 1, 0x13: 2, 0x14: 3, 0x15: 4, 0x17: 5, 0x16: 6, 0x1A: 7, 0x1C: 8,
    ]

    public init(app: AXUIElement, pid: pid_t, inboxPrefix: String, modifier: Modifier,
                onSlot: @escaping (Int) -> Void, onMembership: @escaping () -> Void) {
        self.app = app
        self.pid = pid
        self.inboxPrefix = inboxPrefix
        self.modifier = modifier
        self.onSlot = onSlot
        self.onMembership = onMembership
    }

    @discardableResult
    public func start() -> Bool {
        guard installTap() else { return false }
        startPoll()
        return true
    }

    // MARK: Tap

    private func installTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<KeyboardTrigger>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            printError("❌ Could not create the keyboard event tap.")
            printError("   Grant the terminal BOTH Accessibility and Input Monitoring:")
            printError("   System Settings → Privacy & Security → Input Monitoring (+ Accessibility)")
            return false
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard type == .keyDown else { return pass }

        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // Membership readout (backtick) — available everywhere, not inbox-gated.
        if code == kVKGrave {
            guard isFrontmost(), songTableFocused() else { return pass }
            workQueue.async { [weak self] in self?.onMembership() }
            return nil
        }

        guard let slot = Self.slotKeycodes[code] else { return pass }
        guard modifierSatisfied(event.flags) else { return pass }
        guard isFrontmost() else { return pass }

        lock.lock(); let inbox = cachedInbox; lock.unlock()
        guard inbox else { return pass }
        guard songTableFocused() else { return pass }

        workQueue.async { [weak self] in self?.onSlot(slot) }
        return nil   // swallow so djay never sees the digit
    }

    // MARK: Gate helpers

    private func isFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private func songTableFocused() -> Bool {
        guard let f = getFocusedElement(app) else { return false }
        return getRole(f) == "AXTable" && getTitle(f) == "Playlist"
    }

    private func modifierSatisfied(_ flags: CGEventFlags) -> Bool {
        let cmd = flags.contains(.maskCommand)
        let ctrl = flags.contains(.maskControl)
        let alt = flags.contains(.maskAlternate)
        switch modifier {
        case .none: return !cmd && !ctrl && !alt
        case .ctrl: return ctrl && !cmd && !alt
        case .alt:  return alt && !cmd && !ctrl
        }
    }

    // MARK: Poll (4 Hz)

    private func startPoll() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "inbox-poll"))
        timer.schedule(deadline: .now(), repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        pollTimer = timer
    }

    private func poll() {
        let name = currentPlaylistName(app)
        let inbox = name?.hasPrefix(inboxPrefix) ?? false
        lock.lock(); cachedInbox = inbox; cachedName = name; lock.unlock()

        if lastActive != inbox {
            lastActive = inbox
            if inbox {
                printError("▶ active — inbox \"\(name ?? inboxPrefix)\"")
            } else {
                printError("⏸ paused — viewing \"\(name ?? "?")\"  (keys pass through)")
            }
        }
    }
}
