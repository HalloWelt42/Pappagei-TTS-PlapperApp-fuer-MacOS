import Foundation

/// Tries the reliable, non-destructive Accessibility path first, then falls back
/// to clipboard simulation. Serialized via an actor.
actor TextCaptureCoordinator {
    static let shared = TextCaptureCoordinator()

    func capture() async -> String? {
        if let viaAX = AccessibilityTextGrabber.selectedText() {
            return viaAX
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: PasteboardFallback.grab())
            }
        }
    }
}
