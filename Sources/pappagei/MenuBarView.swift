import SwiftUI
import AppKit
import Combine

struct MenuBarView: View {
    @ObservedObject private var c = SpeechController.shared
    @ObservedObject private var exporter = AudioExporter.shared
    @Environment(\.openWindow) private var openWindow
    @State private var axTrusted = AccessibilityPermission.isTrusted
    @State private var showAdvanced = false
    private let axTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private let models: [(key: String, label: String)] = [
        ("0.6b", "0.6B (schnell)"),
        ("1.7b", "1.7B (Qualität)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            controls
            Divider()
            clipboardRow
            Divider()
            voicePicker
            manageVoicesButton
            modelPicker
            speedRow
            advancedSection
            if !axTrusted {
                Divider()
                permissionRow
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { axTrusted = AccessibilityPermission.isTrusted }
        .onReceive(axTimer) { _ in axTrusted = AccessibilityPermission.isTrusted }
        .onChange(of: c.exportSource) { _, _ in exporter.invalidate() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: c.menuBarSymbol)
            VStack(alignment: .leading, spacing: 1) {
                Text("pappagei").font(.headline)
                Text(c.statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if [.starting, .downloadingOrLoading].contains(c.status) {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                c.speakSelection()
            } label: {
                Label("Auswahl vorlesen", systemImage: "text.viewfinder")
            }
            .disabled(c.status != .ready && !c.isBusy)
            Spacer()
            Button {
                c.pauseResume()
            } label: {
                Image(systemName: c.status == .paused ? "play.fill" : "pause.fill")
            }
            .disabled(!c.isBusy)
            Button {
                c.stop()
            } label: {
                Image(systemName: "stop.fill")
            }
            .disabled(!c.isBusy)
            saveControl
        }
    }

    /// Save the current utterance as an audio file. The icon and hover text
    /// reflect the export state; a fresh file's tooltip shows title, length and
    /// size, and a click saves it.
    @ViewBuilder
    private var saveControl: some View {
        let display = exporter.display(for: c.exportSource)
        if case .generating = display {
            ProgressView()
                .controlSize(.small)
                .frame(width: 22)
                .help("Aufnahme wird erzeugt ...")
        } else {
            Button {
                exporter.primaryAction(for: c.exportSource)
            } label: {
                Image(systemName: saveIcon(display))
                    .foregroundStyle(saveTint(display))
            }
            .disabled(!saveEnabled(display))
            .help(saveHelp(display))
        }
    }

    private var clipboardRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Aus Zwischenablage vorlesen", isOn: $c.clipboardMode)
                .onChange(of: c.clipboardMode) { _, _ in c.save() }
            Button {
                c.speakClipboard()
            } label: {
                Label("Zwischenablage jetzt vorlesen", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.link)
            if c.clipboardMode {
                Text("Kopiere Text (Cmd+C oder Rechtsklick, Kopieren) — pappagei liest ihn automatisch vor. Funktioniert überall, auch im Browser, ohne Bedienungshilfen.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var voicePicker: some View {
        Picker("Stimme", selection: voiceBinding) {
            if !c.speakers.isEmpty {
                Section("Sprecher") {
                    ForEach(c.speakers, id: \.self) { Text($0).tag($0) }
                }
            }
            if !c.customVoices.isEmpty {
                Section("Eigene") {
                    ForEach(c.customVoices) { Text($0.name).tag($0.id) }
                }
            }
        }
        .pickerStyle(.menu)
    }

    private var manageVoicesButton: some View {
        Button {
            openWindow(id: "voices")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("Stimme hinzufügen / verwalten", systemImage: "person.wave.2")
        }
        .buttonStyle(.link)
    }

    private var modelPicker: some View {
        Picker("Modell", selection: modelBinding) {
            ForEach(models, id: \.key) { Text($0.label).tag($0.key) }
        }
        .pickerStyle(.menu)
    }

    private var speedRow: some View {
        HStack {
            Text("Tempo")
            Slider(value: $c.speed, in: 0.5...1.5, step: 0.05) { editing in
                if !editing { c.save() }
            }
            .onChange(of: c.speed) { _, _ in c.applyRate() }
            Text(String(format: "%.2fx", c.speed)).font(.caption).monospacedDigit()
        }
    }

    private var advancedSection: some View {
        DisclosureGroup("Erweitert", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Temperatur")
                    Slider(value: $c.temperature, in: 0.3...1.0, step: 0.05) { editing in
                        if !editing { c.save() }
                    }
                    Text(String(format: "%.2f", c.temperature)).font(.caption).monospacedDigit()
                }
                HStack {
                    Text("Wiederholung")
                    Slider(value: $c.repetitionPenalty, in: 1.0...1.3, step: 0.05) { editing in
                        if !editing { c.save() }
                    }
                    Text(String(format: "%.2f", c.repetitionPenalty)).font(.caption).monospacedDigit()
                }
                Text("Niedrigere Temperatur und höhere Wiederholungs-Strafe verkürzen die Ausgabe.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }

    private var permissionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bedienungshilfen nötig, um markierten Text zu lesen.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Berechtigung erteilen") {
                AccessibilityPermission.prompt()
                AccessibilityPermission.openSettings()
            }
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Ctrl+Shift+R vorlesen/stoppen").font(.caption2).foregroundStyle(.secondary)
                Text("Ctrl+Shift+P Pause").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Beenden") { c.quit() }
        }
    }

    // MARK: save control helpers

    private func saveIcon(_ display: AudioExporter.Display) -> String {
        switch display {
        case .available: return "square.and.arrow.down.fill"
        case .failed: return "exclamationmark.triangle"
        default: return "square.and.arrow.down"
        }
    }

    private func saveTint(_ display: AudioExporter.Display) -> Color {
        switch display {
        case .available: return .green
        case .failed: return .orange
        case .unavailable: return .secondary
        default: return .primary
        }
    }

    private func saveEnabled(_ display: AudioExporter.Display) -> Bool {
        switch display {
        case .unavailable, .generating: return false
        case .available: return true
        case .ready, .failed: return canGenerate
        }
    }

    /// Generation needs a ready model; saving an already-made file does not.
    private var canGenerate: Bool {
        switch c.status {
        case .starting, .downloadingOrLoading, .error: return false
        default: return true
        }
    }

    private func saveHelp(_ display: AudioExporter.Display) -> String {
        switch display {
        case .unavailable:
            return "Zuerst etwas vorlesen, dann als Audiodatei sichern"
        case .ready:
            return canGenerate
                ? "Aktuellen Vorlese-Text als Audiodatei erzeugen"
                : "Modell lädt noch - gleich als Audiodatei sicherbar"
        case .generating:
            return "Aufnahme wird erzeugt ..."
        case .available(let meta):
            return availableHelp(meta)
        case .failed(let message):
            return "\(message) - zum erneuten Versuch klicken"
        }
    }

    private func availableHelp(_ meta: AudioExporter.Meta) -> String {
        let titleLine: String
        if meta.titlePending {
            titleLine = "Titel: wird ermittelt ..."
        } else if let title = meta.title, !title.isEmpty {
            titleLine = "Titel: \(title)"
        } else {
            titleLine = "Titel: -"
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(meta.bytes), countStyle: .file)
        return [
            titleLine,
            "Länge: \(formatDuration(meta.duration))",
            "Größe: \(size)",
            "Format: \(meta.format.uppercased())",
            "Klicken zum Speichern",
        ].joined(separator: "\n")
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var voiceBinding: Binding<String> {
        Binding(get: { c.selectedVoice }, set: { c.selectedVoice = $0; c.save() })
    }

    private var modelBinding: Binding<String> {
        Binding(get: { c.model }, set: { c.switchModel($0) })
    }
}
