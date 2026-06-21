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

public func getSubrole(_ element: AXUIElement) -> String? {
    return getAttr(element, kAXSubroleAttribute) as? String
}

// MARK: - AX Actions

public func getActions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success,
          let arr = names as? [String] else { return [] }
    return arr
}

/// Perform an AX action (e.g. kAXPressAction, kAXShowMenuAction). Returns true on success.
@discardableResult
public func performAction(_ element: AXUIElement, _ action: String) -> Bool {
    return AXUIElementPerformAction(element, action as CFString) == .success
}

// MARK: - Element-valued attributes

/// Read an attribute whose value is itself an AXUIElement (e.g. AXFocusedUIElement).
public func getElementAttr(_ element: AXUIElement, _ attr: String) -> AXUIElement? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

/// Read an attribute whose value is an array of AXUIElements.
public func getElements(_ element: AXUIElement, _ attr: String) -> [AXUIElement] {
    return getAttr(element, attr) as? [AXUIElement] ?? []
}

public func getFocusedElement(_ app: AXUIElement) -> AXUIElement? {
    return getElementAttr(app, kAXFocusedUIElementAttribute)
}

public func getSelectedRows(_ element: AXUIElement) -> [AXUIElement] {
    return getElements(element, kAXSelectedRowsAttribute)
}

public func getDefaultButton(_ window: AXUIElement) -> AXUIElement? {
    return getElementAttr(window, kAXDefaultButtonAttribute)
}

// MARK: - Geometry (global top-left screen coordinates)

public func getPosition(_ element: AXUIElement) -> CGPoint? {
    guard let v = getAttr(element, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
}

public func getSize(_ element: AXUIElement) -> CGSize? {
    guard let v = getAttr(element, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
}
