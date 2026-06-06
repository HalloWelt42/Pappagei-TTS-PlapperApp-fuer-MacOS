import AppKit

/// Captures the user's selected text. Strategy:
///  1. Require Accessibility permission (otherwise abort cleanly — no key simulation,
///     so no system error beep).
///  2. Read the selection via the Accessibility API from the target app (the
///     frontmost non-self app, or the last active one if our menu took focus).
///  3. Only if the target is frontmost and AX yielded nothing, fall back to Cmd+C.
actor TextCaptureCoordinator {
    static let shared = TextCaptureCoordinator()

    func capture() async -> String? {
        if !AXIsProcessTrusted() {
            AppLog.log("capture: not trusted -> abort (no key simulation)")
            return nil
        }

        let target = await Self.resolveTarget()
        AppLog.log("capture: target=\(target.name) pid=\(target.pid.map(String.init) ?? "nil") frontmost=\(target.frontmost)")

        if let pid = target.pid, let text = AccessibilityTextGrabber.selectedText(pid: pid) {
            AppLog.log("capture: AX(app) \(text.count) chars")
            return text
        }
        if let text = AccessibilityTextGrabber.selectedText() {
            AppLog.log("capture: AX(system) \(text.count) chars")
            return text
        }
        if target.frontmost {
            AppLog.log("capture: Cmd+C fallback")
            let copied = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: PasteboardFallback.grab())
                }
            }
            AppLog.log("capture: fallback \(copied?.count ?? 0) chars")
            return copied
        }
        AppLog.log("capture: nothing found")
        return nil
    }

    @MainActor
    private static func resolveTarget() -> (pid: pid_t?, name: String, frontmost: Bool) {
        let selfBundle = Bundle.main.bundleIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != selfBundle {
            return (front.processIdentifier, front.localizedName ?? "", true)
        }
        return (ActiveAppTracker.shared.lastTargetPid, ActiveAppTracker.shared.lastTargetName, false)
    }
}
