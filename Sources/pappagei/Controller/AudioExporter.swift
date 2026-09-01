import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Everything that determines the exported audio. When any field changes, a
/// file generated earlier no longer matches and must be regenerated - so this
/// doubles as the freshness key for the cached export.
struct ExportSource: Equatable {
    let text: String
    let voice: String
    let model: String
    let temperature: Double
    let repetitionPenalty: Double
}

/// Owns the "save the current utterance as an audio file" flow: generate once
/// (into a temp file), expose length/size/format/title for the hover tooltip,
/// then save on demand via a save panel. Kept separate from SpeechController so
/// speaking and exporting stay single-purpose.
@MainActor
final class AudioExporter: ObservableObject {
    static let shared = AudioExporter()

    struct Meta: Equatable {
        var title: String?        // nil while pending, or when no LLM is available
        var titlePending: Bool
        var duration: Double      // seconds
        var bytes: Int
        var format: String        // "mp3" | "wav"
    }

    /// What the save control should show, given the currently exportable source.
    enum Display: Equatable {
        case unavailable          // nothing to export yet
        case ready                // text present, no fresh file for it
        case generating
        case available(Meta)      // a fresh file exists for the current source
        case failed(String)
    }

    private enum Phase: Equatable { case idle, generating, done, failed(String) }

    @Published private var phase: Phase = .idle
    @Published private var meta: Meta?
    private var cachedSource: ExportSource?     // source the file/phase belongs to
    private var fileURL: URL?
    private var task: Task<Void, Never>?
    private let client = TTSClient()

    private init() {}

    // MARK: state for the view

    func display(for source: ExportSource?) -> Display {
        guard let source, !source.text.isEmpty else { return .unavailable }
        guard cachedSource == source else { return .ready }   // stale or never generated
        switch phase {
        case .generating: return .generating
        case .done:
            return .available(meta ?? Meta(title: nil, titlePending: false,
                                           duration: 0, bytes: 0, format: "wav"))
        case .failed(let message): return .failed(message)
        case .idle: return .ready
        }
    }

    /// One click, routed by the current display: generate, save, or retry.
    func primaryAction(for source: ExportSource?) {
        guard let source else { return }
        switch display(for: source) {
        case .ready, .failed: generate(source)
        case .available: save()
        case .generating, .unavailable: break
        }
    }

    // MARK: generation

    private func generate(_ source: ExportSource) {
        task?.cancel()
        cachedSource = source
        meta = nil
        phase = .generating
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.client.exportAudio(
                    text: source.text,
                    voice: source.voice.isEmpty ? nil : source.voice,
                    model: source.model,
                    format: nil,                       // server picks MP3 if it can, else WAV
                    temperature: source.temperature,
                    repetitionPenalty: source.repetitionPenalty)
                if Task.isCancelled { return }
                let url = try self.writeTemp(result)
                self.fileURL = url
                self.meta = Meta(title: nil, titlePending: true,
                                 duration: result.duration, bytes: result.data.count,
                                 format: result.format)
                self.phase = .done
                // The title is optional and slower; never let it hold up the file.
                await self.fillTitle(for: source)
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
                AppLog.log("export error: \(error)")
                self.phase = .failed("Erzeugung fehlgeschlagen")
            }
        }
    }

    private func fillTitle(for source: ExportSource) async {
        let title = await client.generateTitle(text: source.text)
        // A new generation or a source change may have happened while we waited.
        guard !Task.isCancelled, cachedSource == source, phase == .done, var current = meta else { return }
        current.title = title
        current.titlePending = false
        meta = current
    }

    private func writeTemp(_ result: ExportResult) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pappagei-export.\(result.format)")
        try? FileManager.default.removeItem(at: url)
        try result.data.write(to: url)
        return url
    }

    // MARK: saving

    private func save() {
        guard phase == .done, let source = cachedSource, let url = fileURL, let meta else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [meta.format == "mp3" ? UTType.mp3 : UTType.wav]
        panel.nameFieldStringValue = suggestedName(meta, source: source)
        panel.title = "Aufnahme sichern"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            AppLog.log("save error: \(error)")
        }
    }

    private func suggestedName(_ meta: Meta, source: ExportSource) -> String {
        let base = (meta.title?.isEmpty == false) ? meta.title! : "pappagei-Aufnahme"
        return Self.sanitizedFilename(base: base, ext: meta.format, fallback: "pappagei-Aufnahme")
    }

    /// Build a safe file name from an untrusted title via a strict allowlist:
    /// only letters (umlauts included), digits, spaces, hyphen and underscore
    /// survive; everything else - path separators, dots, control and reserved
    /// characters - is replaced. Runs are collapsed, the ends trimmed, the
    /// length capped, and an empty result falls back. The extension is added
    /// here, so a title can never smuggle in its own.
    static func sanitizedFilename(base rawBase: String, ext: String, fallback: String) -> String {
        let trim = CharacterSet(charactersIn: " -_.")
        var name = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: "[^\\p{L}\\p{N} _-]", with: "-",
                                         options: .regularExpression)
        name = name.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        name = name.replacingOccurrences(of: "[-_]{2,}", with: "-", options: .regularExpression)
        name = name.trimmingCharacters(in: trim)
        if name.count > 80 {
            name = String(name.prefix(80)).trimmingCharacters(in: trim)
        }
        if name.isEmpty { name = fallback }
        return "\(name).\(ext)"
    }

    // MARK: invalidation

    /// The exportable source changed: drop any in-flight work and cached file so
    /// the control falls back to "ready" (regenerate) for the new source.
    func invalidate() {
        task?.cancel()
        task = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
        meta = nil
        cachedSource = nil
        if phase != .idle { phase = .idle }
    }
}
