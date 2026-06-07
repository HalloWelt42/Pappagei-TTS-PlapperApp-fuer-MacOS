import SwiftUI
import AppKit

@MainActor
final class SpeechController: ObservableObject {
    static let shared = SpeechController()

    enum Status: Equatable {
        case starting, downloadingOrLoading, ready, speaking, paused, error(String)
    }

    @Published private(set) var status: Status = .starting
    @Published private(set) var statusText = "Starte pappagei ..."
    @Published var speakers: [String] = []
    @Published var customVoices: [CustomVoice] = []
    @Published var selectedVoice: String = ""        // base speaker or custom voice id
    @Published var model = "1.7b-clone"
    @Published var speed: Double = 1.0
    @Published var temperature: Double = 0.7
    @Published var repetitionPenalty: Double = 1.1
    @Published var clipboardMode: Bool = false

    private let client = TTSClient()
    private let audio = AudioPlayer()
    private let sidecar = SidecarProcess()
    private var hotKey: GlobalHotKey?
    private var speakTask: Task<Void, Never>?
    private var clipboardTimer: Timer?
    private var lastClipboardChange = 0

    private init() {
        load()
    }

    var menuBarSymbol: String {
        switch status {
        case .speaking: return "speaker.wave.3.fill"
        case .paused: return "pause.circle"
        case .error: return "exclamationmark.triangle"
        default: return "bird"
        }
    }

    var isBusy: Bool { [.speaking, .paused].contains(status) }

    var isCustom: Bool { customVoices.contains { $0.id == selectedVoice } }

    // MARK: lifecycle

    func onLaunch() {
        AppLog.log("onLaunch; trusted=\(AccessibilityPermission.isTrusted); backend=\(sidecar.backendPath); installed=\(sidecar.isInstalled)")
        ActiveAppTracker.shared.start()
        guard sidecar.isInstalled else {
            status = .error("Backend fehlt")
            statusText = "Backend nicht gefunden: \(sidecar.backendPath)"
            return
        }
        sidecar.start()
        hotKey = GlobalHotKey(keyCode: GlobalHotKey.keyR,
                              modifiers: GlobalHotKey.controlShift) { [weak self] in
            self?.toggleSpeakSelection()
        }
        startClipboardWatch()
        audio.setRate(speed)
        Task { await waitUntilReady() }
    }

    func shutdown() {
        speakTask?.cancel()
        audio.stop()
        sidecar.stop()
    }

    private func waitUntilReady() async {
        status = .downloadingOrLoading
        statusText = "Lade Sprachmodell (Erststart kann dauern) ..."
        for _ in 0..<600 {                      // up to ~5 min for first model download
            if let h = await client.health(), h.loaded {
                await refreshVoices()
                status = .ready
                statusText = "Bereit"
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        status = .error("Zeitüberschreitung")
        statusText = "Modell konnte nicht geladen werden"
    }

    func refreshVoices() async {
        guard let v = await client.voices() else { return }
        speakers = v.speakers
        customVoices = v.custom
        if selectedVoice.isEmpty {
            selectedVoice = v.speakers.first ?? ""
        }
    }

    @discardableResult
    func importVoice(name: String, path: String, transcript: String?, speaker: String) async -> Bool {
        guard let v = await client.importVoice(name: name, audioPath: path,
                                               transcript: transcript, speaker: speaker) else {
            return false
        }
        await refreshVoices()
        selectedVoice = v.id
        save()
        return true
    }

    func deleteVoice(_ id: String) async {
        _ = await client.deleteVoice(id: id)
        await refreshVoices()
        if selectedVoice == id {
            selectedVoice = speakers.first ?? ""
            save()
        }
    }

    // MARK: speaking

    func toggleSpeakSelection() {
        if isBusy { stop() } else { speakSelection() }
    }

    func speakSelection() {
        AppLog.log("speakSelection; status=\(status); trusted=\(AccessibilityPermission.isTrusted)")
        if status != .ready && !isBusy {
            if status == .downloadingOrLoading { statusText = "Modell lädt noch ..." }
            return
        }
        let voice = selectedVoice
        let model = self.model
        let speed = self.speed
        speakTask?.cancel()
        speakTask = Task { [weak self] in
            guard let self else { return }
            let captured = await TextCaptureCoordinator.shared.capture()
            guard let text = captured, !text.isEmpty else {
                AppLog.log("speakSelection: capture leer (trusted=\(AccessibilityPermission.isTrusted))")
                self.statusText = AccessibilityPermission.isTrusted
                    ? "Kein Text markiert"
                    : "Bitte Bedienungshilfen erlauben"
                return
            }
            await self.run(text: text, voice: voice, model: model, speed: speed)
        }
    }

    func speak(text: String) {
        speakTask?.cancel()
        speakTask = Task { [weak self] in
            guard let self else { return }
            await self.run(text: text, voice: self.selectedVoice, model: self.model, speed: self.speed)
        }
    }

    // MARK: clipboard mode (works everywhere, no Accessibility needed)

    private func startClipboardWatch() {
        lastClipboardChange = NSPasteboard.general.changeCount
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkClipboard() }
        }
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        let change = pasteboard.changeCount
        guard change != lastClipboardChange else { return }
        lastClipboardChange = change
        guard clipboardMode else { return }
        if [Status.starting, .downloadingOrLoading].contains(status) { return }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        AppLog.log("clipboard changed -> read \(text.count) chars")
        speak(text: text)
    }

    func speakClipboard() {
        let pasteboard = NSPasteboard.general
        lastClipboardChange = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            statusText = "Zwischenablage leer"
            return
        }
        speak(text: text)
    }

    func applyRate() {
        audio.setRate(speed)
    }

    private func run(text: String, voice: String, model: String, speed: Double) async {
        status = .speaking
        statusText = "Liest vor ..."
        audio.setRate(speed)        // tempo via audio time-stretch (model speed is unreliable)
        audio.begin()
        let voiceArg = voice.isEmpty ? nil : voice
        // A cloned (custom) voice needs a CustomVoice model.
        let usingCustom = customVoices.contains { $0.id == voice }
        let effectiveModel = (usingCustom && !model.hasSuffix("-clone")) ? model + "-clone" : model
        AppLog.log("synth start: \(text.count) chars, model=\(effectiveModel), voice=\(voiceArg ?? "default"), rate=\(speed)")
        do {
            try await client.synthesizeStream(text: text, voice: voiceArg,
                                              model: effectiveModel, speed: 1.0,
                                              temperature: self.temperature,
                                              repetitionPenalty: self.repetitionPenalty) { [audio] data in
                audio.enqueue(data)
            }
            if status == .speaking {
                status = .ready
                statusText = "Fertig"
            }
        } catch is CancellationError {
            // user stopped; leave whatever state stop() set
        } catch {
            status = .error("\(error)")
            statusText = "Fehler bei der Synthese"
        }
    }

    func pauseResume() {
        switch status {
        case .speaking: audio.pause(); status = .paused; statusText = "Pausiert"
        case .paused: audio.resume(); status = .speaking; statusText = "Liest vor ..."
        default: break
        }
    }

    func stop() {
        speakTask?.cancel()
        speakTask = nil
        audio.stop()
        status = .ready
        statusText = "Bereit"
    }

    func switchModel(_ key: String) {
        model = key
        save()
        Task {
            status = .downloadingOrLoading
            statusText = "Wechsle Modell ..."
            _ = await client.warmup()
            await refreshVoices()
            status = .ready
            statusText = "Bereit"
        }
    }

    func quit() {
        shutdown()
        NSApp.terminate(nil)
    }

    // MARK: persistence

    private func load() {
        let d = UserDefaults.standard
        if let m = d.string(forKey: "model") { model = m }
        if let v = d.string(forKey: "voice") { selectedVoice = v }
        let s = d.double(forKey: "speed")
        if s > 0 { speed = s }
        let t = d.double(forKey: "temperature")
        if t > 0 { temperature = t }
        let r = d.double(forKey: "repetitionPenalty")
        if r > 0 { repetitionPenalty = r }
        clipboardMode = d.bool(forKey: "clipboardMode")
    }

    func save() {
        let d = UserDefaults.standard
        d.set(model, forKey: "model")
        d.set(selectedVoice, forKey: "voice")
        d.set(speed, forKey: "speed")
        d.set(temperature, forKey: "temperature")
        d.set(repetitionPenalty, forKey: "repetitionPenalty")
        d.set(clipboardMode, forKey: "clipboardMode")
    }
}
