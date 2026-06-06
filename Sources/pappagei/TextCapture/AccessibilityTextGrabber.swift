import ApplicationServices

/// Reads the selected text of the focused UI element via the Accessibility API.
/// Non-destructive (does not touch the clipboard). Needs Accessibility permission.
enum AccessibilityTextGrabber {
    static func selectedText() -> String? {
        let system = AXUIElementCreateSystemWide()

        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedElement = focused,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else { return nil }

        let element = focusedElement as! AXUIElement
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
