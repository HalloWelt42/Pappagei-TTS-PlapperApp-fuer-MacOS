import SwiftUI
import AppKit

@main
struct pappageiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var controller = SpeechController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            Image(systemName: controller.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Window("Stimmen verwalten", id: "voices") {
            VoiceManagerView()
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let serviceProvider = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar agent: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
        // System-wide "Vorlesen mit pappagei" service (no Accessibility needed).
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
        SpeechController.shared.onLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SpeechController.shared.shutdown()
    }
}
