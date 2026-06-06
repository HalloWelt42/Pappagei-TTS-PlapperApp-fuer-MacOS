import AppKit

/// Remembers the most recently active application that is NOT pappagei, so we can
/// read its selection even when our menu took focus (menu-bar button case).
final class ActiveAppTracker {
    static let shared = ActiveAppTracker()
    private(set) var lastTargetPid: pid_t?
    private(set) var lastTargetName: String = ""

    private init() {}

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
            self?.lastTargetPid = app.processIdentifier
            self?.lastTargetName = app.localizedName ?? ""
        }
    }
}
