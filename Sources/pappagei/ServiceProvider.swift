import AppKit

/// Provides the system-wide "Vorlesen mit pappagei" Service. macOS passes the
/// selected text directly (no Accessibility needed), and we read it aloud.
final class ServiceProvider: NSObject {
    @objc func readSelection(_ pasteboard: NSPasteboard,
                             userData: String,
                             error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        AppLog.log("service readSelection: \(text.count) chars")
        DispatchQueue.main.async {
            SpeechController.shared.speak(text: text)
        }
    }
}
