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
// Hotkeys fire whenever djay is frontmost — from ANY playlist. Sorting from a
// playlist adds to [N] and removes the track from that playlist; sorting from
// the main collection just adds (there's no "Remove from Playlist", so the
// remove is skipped — see PlaylistSorter's guard).

public final class KeyboardTrigger {
    private let app: AXUIElement
    private let pid: pid_t
    private let onSlot: (Int) -> Void
    private let onMembership: () -> Void

    private let workQueue = DispatchQueue(label: "playlist-sort")
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

    public init(app: AXUIElement, pid: pid_t,
                onSlot: @escaping (Int) -> Void, onMembership: @escaping () -> Void) {
        self.app = app
        self.pid = pid
        self.onSlot = onSlot
        self.onMembership = onMembership
    }

    @discardableResult
    public func start() -> Bool {
        guard installHandler() else { return false }
        registerHotkeys()
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
        guard isFrontmost() else { return }   // only act while djay is the active app
        if id == 0 {
            workQueue.async { [weak self] in self?.onMembership() }
        } else {
            workQueue.async { [weak self] in self?.onSlot(id) }
        }
    }

    private func isFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }
}

private func fourCharCode(_ s: String) -> FourCharCode {
    var result: FourCharCode = 0
    for ch in s.utf16.prefix(4) { result = (result << 8) + FourCharCode(ch) }
    return result
}
