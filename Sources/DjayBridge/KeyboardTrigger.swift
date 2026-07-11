import Cocoa
import Foundation

// MARK: - Vim-style key interception via CGEventTap
//
// Active CGEventTap that intercepts bare keys ONLY while djay is frontmost, so
// the same keys still type normally in every other app. Replaces the old Carbon
// RegisterEventHotKey approach, which grabbed keys system-wide (fine for F13–F18
// that nothing else uses, unusable for bare 1/j/k/h/l/enter/m).
//
//   1 2 3 5 8  → sort selected track into playlist "[N] …"
//   j / k      → down / up the track list (posts ↓ / ↑)
//   h / l      → beat jump back / forward (posts ⌥A / ⌥S)
//   enter      → load selected track on Deck 1
//   m          → membership readout
//
// Only fires with NO modifier held, so Cmd+1 etc. still reach djay. Needs the
// process trusted for Accessibility (already required for the menu-driving);
// macOS may additionally list it under Input Monitoring.

public enum KeyAction {
    case sort(Int)
    case navDown
    case navUp
    case beatBack
    case beatForward
    case load
    case membership
}

public final class KeyboardTrigger {
    private let pid: pid_t
    private let onAction: (KeyAction) -> Void

    private let workQueue = DispatchQueue(label: "playlist-sort")
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // keycode (macOS virtual) → action.
    private static let map: [Int64: KeyAction] = [
        0x12: .sort(1), 0x13: .sort(2), 0x14: .sort(3), 0x17: .sort(5), 0x1C: .sort(8),
        0x26: .navDown,      // j
        0x28: .navUp,        // k
        0x04: .beatBack,     // h
        0x25: .beatForward,  // l
        0x24: .load,         // return
        0x2E: .membership,   // m
    ]

    // Menu-driving actions must not repeat-fire when the key is held; nav/beat may.
    private static func ignoresRepeat(_ a: KeyAction) -> Bool {
        switch a {
        case .navDown, .navUp, .beatBack, .beatForward: return false
        default: return true
        }
    }

    public init(pid: pid_t, onAction: @escaping (KeyAction) -> Void) {
        self.pid = pid
        self.onAction = onAction
    }

    @discardableResult
    public func start() -> Bool {
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            let me = Unmanaged<KeyboardTrigger>.fromOpaque(userInfo!).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,   // active tap — can swallow events
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            printError("❌ Could not create the keyboard event tap.")
            printError("   Grant Accessibility to your terminal — and Input Monitoring if prompted.")
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    // MARK: Tap callback — keep light, NO blocking AX here

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)

        // macOS disables the tap if the callback is ever too slow, or on some user
        // input — re-enable and let the event through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passthrough
        }
        guard type == .keyDown else { return passthrough }

        // Only intercept while djay is the active app.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return passthrough
        }
        // Any real modifier held → leave the key for djay/system (Cmd+1, etc).
        let mods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        if !event.flags.intersection(mods).isEmpty { return passthrough }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let action = Self.map[keycode] else { return passthrough }

        // Swallow held-key repeats for menu actions so a hold can't double-fire.
        if Self.ignoresRepeat(action), event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return nil
        }
        dispatch(action)
        return nil   // swallow — djay never sees the key
    }

    private func dispatch(_ action: KeyAction) {
        switch action {
        // Emulation is instant and touches no AX — run it inline so it never
        // queues behind a slow sort/load.
        case .navDown:     postKey(0x7D)                         // ↓
        case .navUp:       postKey(0x7E)                         // ↑
        case .beatBack:    postKey(0x00, flags: .maskAlternate)  // ⌥A
        case .beatForward: postKey(0x01, flags: .maskAlternate)  // ⌥S
        // Menu-driving runs on the serial queue so it can't block the tap callback.
        default:           workQueue.async { [weak self] in self?.onAction(action) }
        }
    }
}
