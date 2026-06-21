import Carbon.HIToolbox
import Cocoa
import Foundation

// MARK: - Global hotkey trigger (F13–F18) via Carbon RegisterEventHotKey
//
// Uses system hotkeys instead of a CGEventTap, which means NO Input Monitoring
// permission is needed (and no Accessibility for the keys themselves — only the
// menu-driving in PlaylistSorter uses Accessibility, already granted).
//
//   F13→slot 1   F14→slot 2   F15→slot 3   F16→slot 5   F17→slot 8
//   F18→ membership readout (which playlists the selected track is in)
//
// Hotkeys are registered globally (they don't reach other apps while running),
// but the SORT action is gated: it only fires when djay is frontmost and the
// current playlist is the inbox (name starts with `inboxPrefix`). Membership is
// available whenever djay is frontmost.

public final class KeyboardTrigger {
    private let app: AXUIElement
    private let pid: pid_t
    private let inboxPrefix: String
    private let onSlot: (Int) -> Void
    private let onMembership: () -> Void

    private let lock = NSLock()
    private var cachedInbox = false
    private var lastActive: Bool?

    private let workQueue = DispatchQueue(label: "playlist-sort")
    private var pollTimer: DispatchSourceTimer?
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?

    // (virtual keycode, hotkey id). id == slot number for sorts; id 0 == membership.
    private static let hotkeys: [(keycode: UInt32, id: Int)] = [
        (UInt32(kVK_F13), 1),
        (UInt32(kVK_F14), 2),
        (UInt32(kVK_F15), 3),
        (UInt32(kVK_F16), 5),
        (UInt32(kVK_F17), 8),
        (UInt32(kVK_F18), 0),   // membership
    ]

    public init(app: AXUIElement, pid: pid_t, inboxPrefix: String,
                onSlot: @escaping (Int) -> Void, onMembership: @escaping () -> Void) {
        self.app = app
        self.pid = pid
        self.inboxPrefix = inboxPrefix
        self.onSlot = onSlot
        self.onMembership = onMembership
    }

    @discardableResult
    public func start() -> Bool {
        guard installHandler() else { return false }
        registerHotkeys()
        startPoll()
        return true
    }

    // MARK: Carbon hotkey plumbing

    private func installHandler() -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userInfo in
            guard let event, let userInfo else { return noErr }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if err == noErr {
                Unmanaged<KeyboardTrigger>.fromOpaque(userInfo).takeUnretainedValue()
                    .handle(id: Int(hkID.id))
            }
            return noErr
        }
        let status = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                                         Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        if status != noErr {
            printError("❌ Could not install the hotkey handler (status \(status)).")
            return false
        }
        return true
    }

    private func registerHotkeys() {
        let signature = fourCharCode("DJSR")
        for (keycode, id) in Self.hotkeys {
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: signature, id: UInt32(id))
            let status = RegisterEventHotKey(keycode, 0, hkID, GetApplicationEventTarget(), 0, &ref)
            if status != noErr {
                printError("⚠ could not register hotkey (keycode \(keycode), status \(status)) — it may be taken by another app.")
            }
            hotKeyRefs.append(ref)
        }
    }

    private func handle(id: Int) {
        guard isFrontmost() else { return }
        if id == 0 {
            workQueue.async { [weak self] in self?.onMembership() }
            return
        }
        lock.lock(); let inbox = cachedInbox; lock.unlock()
        guard inbox else { return }   // sorts only fire while viewing the inbox
        workQueue.async { [weak self] in self?.onSlot(id) }
    }

    private func isFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    // MARK: Status poll (4 Hz) — drives the active/paused indicator + cached gate

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
        lock.lock(); cachedInbox = inbox; lock.unlock()

        if lastActive != inbox {
            lastActive = inbox
            if inbox {
                printError("▶ active — inbox \"\(name ?? inboxPrefix)\"")
            } else {
                printError("⏸ paused — viewing \"\(name ?? "?")\"  (F13–F17 inert)")
            }
        }
    }
}

private func fourCharCode(_ s: String) -> FourCharCode {
    var result: FourCharCode = 0
    for ch in s.utf16.prefix(4) { result = (result << 8) + FourCharCode(ch) }
    return result
}
