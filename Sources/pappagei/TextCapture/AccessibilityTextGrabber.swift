import ApplicationServices

/// Reads the selected text of the focused UI element via the Accessibility API.
/// Non-destructive (does not touch the clipboard). Needs Accessibility permission.
enum AccessibilityTextGrabber {
    /// Selection from the system-wide focused element (works when the source app is frontmost).
    static func selectedText() -> String? {
        selectedText(from: AXUIElementCreateSystemWide())
    }

    /// Selection from a specific application's focused element (works even when our
    /// menu is frontmost, e.g. when triggered from the menu-bar button).
    static func selectedText(pid: pid_t) -> String? {
        selectedText(from: AXUIElementCreateApplication(pid))
    }

    private static func selectedText(from root: AXUIElement) -> String? {
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedElement = focused,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else { return nil }

        let element = focusedElement as! AXUIElement
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
