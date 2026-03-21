import Cocoa
import ApplicationServices

// MARK: - Stderr helper

public func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - Find djay Pro

public struct DjayApp {
    public let element: AXUIElement
    public let pid: pid_t
}

public func findDjayPro() -> DjayApp? {
    let apps = NSWorkspace.shared.runningApplications
    guard let djay = apps.first(where: {
        $0.bundleIdentifier?.contains("algoriddim") == true ||
        $0.localizedName?.contains("djay") == true
    }) else {
        printError("❌ djay Pro is not running")
        return nil
    }
    let pid = djay.processIdentifier
    printError("✅ Found djay Pro (PID: \(pid))")
    return DjayApp(element: AXUIElementCreateApplication(pid), pid: pid)
}

// MARK: - Check accessibility permission

public func checkAccessibilityPermission(_ app: AXUIElement) -> Bool {
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value)
    if result == .cannotComplete || result == .apiDisabled {
        printError("❌ Accessibility permission not granted!")
        printError("   Go to: System Settings → Privacy & Security → Accessibility")
        printError("   Add Terminal.app (or your terminal emulator)")
        return false
    }
    return true
}

// MARK: - AX Helpers

public func getAttr(_ element: AXUIElement, _ attr: String) -> AnyObject? {
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
    return result == .success ? value : nil
}

public func getChildren(_ element: AXUIElement) -> [AXUIElement] {
    guard let children = getAttr(element, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
    return children
}

public func getRole(_ element: AXUIElement) -> String? {
    return getAttr(element, kAXRoleAttribute) as? String
}

public func getLabel(_ element: AXUIElement) -> String? {
    return getAttr(element, kAXDescriptionAttribute) as? String
}

public func getValue(_ element: AXUIElement) -> String? {
    return getAttr(element, kAXValueAttribute) as? String
}

public func getTitle(_ element: AXUIElement) -> String? {
    return getAttr(element, kAXTitleAttribute) as? String
}
