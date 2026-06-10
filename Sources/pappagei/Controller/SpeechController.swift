import SwiftUI
import AppKit

@MainActor
final class SpeechController: ObservableObject {
    static let shared = SpeechController()

    /// Known model keys; keep in sync with the picker in MenuBarView.
    static let validModels = ["0.6b", "1.7b"]
    static let defaultModel = "0.6b"

    enum Status: Equatable {
        case starting, downloadingOrLoading, ready, speaking, paused, error(String)
    }

    @Published private(set) var status: Status = .starting
    @Published private(set) var statusText = "Starte pappagei ..."
    @Published var speakers: [String] = []
    @Published var customVoices: [CustomVoice] = []
    @Published var selectedVoice: String = ""        // base speaker or custom voice id
    @Published var model = SpeechController.defaultModel
    @Published var speed: Double = 1.0
    @Published var temperature: Double = 0.7
    @Published var repetitionPenalty: Double = 1.1
    @Published var clipboardMode: Bool = false

    private let client = TTSClient()
    private let audio = AudioPlayer()
    private let sidecar = SidecarProcess()
    private var hotKey: GlobalHotKey?
    private var pauseHotKey: GlobalHotKey?
    private var speakTask: Task<Void, Never>?
    private var healthWatchTask: Task<Void, Never>?

    private static let healthFailureLimit = 6     // x 5 s interval = ~30 s outage
    private static let backendRestartLimit = 3
    private var clipboardTimer: Timer?
    private var lastClipboardChange = 0
    private var errorClearWork: DispatchWorkItem?

    // Current utterance, kept for progress display and for resuming the
    // pipeline at a sentence boundary after an audio device change.
    private var currentSentences: [String] = []
    private var playedSentences = 0
    private var currentVoice = ""
    private var currentModel = ""
    private var currentSpeed = 1.0

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
            if sidecar.sourcesPresent {
                // Sources are there but the venv is broken (machine migration,
                // Python update): point at the repair path instead of "missing".
                showBackendDefect()
            } else {
                status = .error("Backend fehlt")
                statusText = "Backend nicht gefunden: \(sidecar.backendPath)"
            }
            return
        }
        sidecar.start()
        hotKey = GlobalHotKey(keyCode: GlobalHotKey.keyR,
                              modifiers: GlobalHotKey.controlShift) { [weak self] in
            self?.toggleSpeakSelection()
        }
        pauseHotKey = GlobalHotKey(keyCode: GlobalHotKey.keyP,
                                   modifiers: GlobalHotKey.controlShift) { [weak self] in
            guard let self, self.isBusy else { return }
            self.pauseResume()
        }
        startClipboardWatch()
        audio.setRate(speed)
        audio.onInterruption = { [weak self] in self?.resumeAfterAudioInterruption() }
        Task {
            await waitUntilReady()
            // Always watch from here on -- even if the sidecar died during
            // startup, the watchdog owns restarting and the defect verdict.
            startHealthWatchdog()
        }
    }

    /// The output device changed mid-utterance; scheduled audio is gone.
    /// Restart the pipeline at the first sentence that has not fully played.
    private func resumeAfterAudioInterruption() {
        guard isBusy else { return }
        AppLog.log("audio route changed -> resume at sentence \(playedSentences + 1)")
        speakTask?.cancel()
        speakTask = Task { [weak self] in
            guard let self else { return }
            await self.runPipeline(from: self.playedSentences)
        }
    }

    func shutdown() {
        healthWatchTask?.cancel()
        speakTask?.cancel()
        audio.stop()
        sidecar.stop()
    }

    @discardableResult
    private func waitUntilReady(announce: String = "Lade Sprachmodell (Erststart kann dauern) ...") async -> Bool {
        status = .downloadingOrLoading
        statusText = announce
        var lastBytes = -1
        for _ in 0..<600 {                      // up to ~5 min for first model download
            if Task.isCancelled { return false }
            guard sidecar.isRunning else {
                // Dead process: report failure fast instead of polling for five
                // minutes. The health watchdog decides whether to restart or to
                // declare the backend defective.
                AppLog.log("waitUntilReady: sidecar not running")
                return false
            }
            if let h = await client.health(timeout: 3) {
                if h.loaded {
                    await refreshVoices()
                    status = .ready
                    statusText = "Bereit"
                    return true
                }
                updateLoadingProgress(h, lastBytes: &lastBytes)
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        status = .error("Zeitüberschreitung")
        statusText = "Modell konnte nicht geladen werden"
        return false
    }

    private func showBackendDefect() {
        AppLog.log("backend defect shown (\(sidecar.backendPath))")
        status = .error("backend")
        statusText = "Backend defekt - bitte ./install.sh erneut ausführen (\(sidecar.backendPath))"
    }

    /// Distinguish "downloading" (cache bytes grow between polls) from plain
    /// "loading"; the first poll keeps whatever text is already showing.
    private func updateLoadingProgress(_ h: Health, lastBytes: inout Int) {
        guard h.loading == true, let bytes = h.download_bytes else { return }
        if lastBytes >= 0 && bytes > lastBytes {
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            statusText = "Modell wird heruntergeladen ... (\(size))"
        } else if lastBytes >= 0 {
            statusText = "Modell wird geladen ..."
        }
        lastBytes = bytes
    }

    /// Keep an eye on the sidecar and restart it if it goes away mid-session
    /// (crash, kill, hung Metal call). One task, no reentrancy.
    private func startHealthWatchdog() {
        healthWatchTask?.cancel()
        healthWatchTask = Task { [weak self] in
            var failures = 0
            var attempts = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                let processAlive = self.sidecar.isRunning
                if processAlive, let h = await self.client.health(timeout: 3) {
                    failures = 0
                    attempts = 0
                    // Heal a stale error state (e.g. a first download that
                    // outlived the startup timeout and finished later).
                    if case .error = self.status, h.loaded {
                        await self.refreshVoices()
                        self.status = .ready
                        self.statusText = "Bereit"
                    }
                    continue
                }
                failures = processAlive ? failures + 1 : Self.healthFailureLimit
                guard failures >= Self.healthFailureLimit else { continue }
                failures = 0
                attempts += 1
                AppLog.log("health watchdog: backend down (process \(processAlive ? "alive" : "gone")), restart \(attempts)/\(Self.backendRestartLimit)")
                self.speakTask?.cancel()
                self.audio.stop()
                self.status = .downloadingOrLoading
                self.statusText = "Backend wird neu gestartet ..."
                self.sidecar.stop()
                try? await Task.sleep(for: .seconds(Double(min(8, 2 * attempts))))
                self.sidecar.start()
                if await self.waitUntilReady(announce: "Backend wird neu gestartet ...") {
                    attempts = 0
                } else if attempts >= Self.backendRestartLimit {
                    AppLog.log("health watchdog: giving up after \(attempts) restarts")
                    self.showBackendDefect()
                    return
                }
            }
        }
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
        if isBusy {
            stop()
        } else if AccessibilityPermission.isTrusted {
            speakSelection()
        } else {
            // No Accessibility granted: still useful system-wide by reading the clipboard.
            speakClipboard()
        }
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

    /// Sample sentence for voice previews in the manager window.
    static let previewText = "Hallo, dies ist eine Hörprobe von pappagei."

    func speak(text: String) {
        speak(text: text, voice: selectedVoice)
    }

    /// Speak with an explicit voice (used by per-voice previews); the selection
    /// in the menu stays untouched.
    func speak(text: String, voice: String) {
        speakTask?.cancel()
        speakTask = Task { [weak self] in
            guard let self else { return }
            await self.run(text: text, voice: voice, model: self.model, speed: self.speed)
        }
    }

    // MARK: clipboard mode (works everywhere, no Accessibility needed)

    private func startClipboardWatch() {
        lastClipboardChange = NSPasteboard.general.changeCount
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkClipboard() }
        }
    }

    /// Pasteboard types that mark a copy as not-for-consumption: concealed
    /// (password managers) or transient (our own restore, clipboard tools).
    private static let sensitivePasteboardTypes: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
    ]

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        let change = pasteboard.changeCount
        guard change != lastClipboardChange else { return }
        lastClipboardChange = change
        guard clipboardMode else { return }
        if ClipboardWatchGuard.isSuppressed { return }
        if pasteboard.availableType(from: Self.sensitivePasteboardTypes) != nil {
            AppLog.log("clipboard changed -> concealed/transient, skip")
            return
        }
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
        let sentences = SentenceSegmenter.segments(for: text)
        guard !sentences.isEmpty else { return }
        currentSentences = sentences
        playedSentences = 0
        currentVoice = voice
        currentModel = model
        currentSpeed = speed
        AppLog.log("synth start: \(text.count) chars, \(sentences.count) sentences, model=\(model), voice=\(voice.isEmpty ? "default" : voice), rate=\(speed)")
        await runPipeline(from: 0)
    }

    /// Synthesize and play the current utterance sentence by sentence, starting
    /// at `startIndex` (greater than 0 when resuming after a device change).
    /// A look-ahead throttle keeps at most two sentences synthesized beyond
    /// what has actually played, so pause stays cheap and stop wastes little.
    private func runPipeline(from startIndex: Int) async {
        let sentences = currentSentences
        let n = sentences.count
        status = .speaking
        statusText = n > 1 ? "Liest vor (Satz \(min(startIndex + 1, n)) von \(n))" : "Liest vor ..."
        audio.setRate(currentSpeed)   // tempo via audio time-stretch (model speed is unreliable)
        audio.begin()
        let voiceArg = currentVoice.isEmpty ? nil : currentVoice
        var failuresInARow = 0
        for i in startIndex..<n {
            while i - playedSentences > 2 {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if Task.isCancelled { return }
            do {
                try await client.synthesizeStream(text: sentences[i], voice: voiceArg,
                                                  model: currentModel, speed: 1.0,
                                                  temperature: self.temperature,
                                                  repetitionPenalty: self.repetitionPenalty) { [audio] data in
                    audio.enqueue(data)
                }
                failuresInARow = 0
            } catch {
                // Stopping (or starting a new utterance) cancels this task; URLSession
                // reports that as URLError.cancelled, not CancellationError -- so key
                // off the cancellation itself and never treat it as a failure.
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    return
                }
                AppLog.log("synth error sentence \(i + 1)/\(n): \(error)")
                failuresInARow += 1
                // A network-level error means the backend is gone (the watchdog
                // takes over); repeated synthesis errors are equally hopeless.
                if error is URLError || failuresInARow >= 3 {
                    audio.stop()
                    status = .error("synthese")
                    statusText = "Fehler bei der Synthese"
                    scheduleErrorAutoClear()
                    return
                }
            }
            // Marker even after a failed sentence, so progress and the resume
            // index stay consistent with what was scheduled.
            audio.scheduleMarker { [weak self] in
                Task { @MainActor in self?.sentencePlayed(i) }
            }
        }
        audio.endStream()
        // All bytes are in; stay "speaking" until the audio has actually finished
        // playing, so pause and stop stay usable for the whole utterance.
        while !audio.isDrained {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(80))
        }
        if status == .speaking {
            status = .ready
            statusText = "Fertig"
        }
    }

    private func sentencePlayed(_ index: Int) {
        playedSentences = max(playedSentences, index + 1)
        let n = currentSentences.count
        if status == .speaking && n > 1 && playedSentences < n {
            statusText = "Liest vor (Satz \(playedSentences + 1) von \(n))"
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

    /// A one-off synthesis error shouldn't brand the menu-bar icon (warning triangle)
    /// forever; return to a normal, usable state after a short delay.
    private func scheduleErrorAutoClear() {
        errorClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .error = self.status {
                    self.status = .ready
                    self.statusText = "Bereit"
                }
            }
        }
        errorClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func switchModel(_ key: String) {
        guard Self.validModels.contains(key) else { return }
        model = key
        save()
        Task {
            status = .downloadingOrLoading
            statusText = "Wechsle Modell ..."
            // Drive the switch now so a first-time download shows its progress
            // here instead of hiding behind the first read.
            async let switched = client.switchModel(key)
            var lastBytes = -1
            for _ in 0..<3600 {                 // up to ~30 min for a download
                try? await Task.sleep(for: .milliseconds(500))
                guard let h = await client.health(timeout: 3) else { break }  // watchdog takes over
                if h.loaded && h.loading != true && h.model == key { break }
                updateLoadingProgress(h, lastBytes: &lastBytes)
            }
            _ = await switched
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
        if let m = d.string(forKey: "model") {
            if Self.validModels.contains(m) {
                model = m
            } else {
                // Stale/unknown key (e.g. "1.7b-clone" from an older build):
                // fall back to the default and heal the stored value.
                model = Self.defaultModel
                d.set(model, forKey: "model")
            }
        }
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
