import Foundation

/// Briefly mutes the clipboard watcher while we touch the pasteboard ourselves
/// (Cmd+C fallback grab and its restore). Without this, the watcher would read
/// the grabbed selection and the restored old contents as fresh copies.
/// Thread-safe: the fallback runs off-main, the watcher timer on main.
enum ClipboardWatchGuard {
    private static let lock = NSLock()
    private static var suppressedUntil = Date.distantPast

    static func suppress(for seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        suppressedUntil = max(suppressedUntil, Date().addingTimeInterval(seconds))
    }

    static var isSuppressed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Date() < suppressedUntil
    }
}
