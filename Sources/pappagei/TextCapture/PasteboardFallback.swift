import AppKit
import CoreGraphics

/// Fallback when the Accessibility API yields nothing (e.g. some browsers):
/// simulate Cmd+C, read the clipboard, then restore the previous contents.
/// Blocks briefly, so call it off the main thread.
enum PasteboardFallback {
    private static let keyC: CGKeyCode = 0x08

    static func grab() -> String? {
        // Mute the clipboard watcher for the whole grab-and-restore dance,
        // so neither the grabbed selection nor the restore is auto-read.
        ClipboardWatchGuard.suppress(for: 1.5)
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        let before = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)

        var captured: String?
        for _ in 0..<20 {
            usleep(15_000)
            if pasteboard.changeCount != before {
                captured = pasteboard.string(forType: .string)
                break
            }
        }

        if captured != nil, let previous {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                ClipboardWatchGuard.suppress(for: 1.5)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(previous, forType: .string)
                // Mark the restore as transient so clipboard tools ignore it too.
                pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            }
        }
        return captured
    }
}
