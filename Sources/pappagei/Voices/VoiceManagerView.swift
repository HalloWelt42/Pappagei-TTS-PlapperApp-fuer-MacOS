import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct VoiceManagerView: View {
    @ObservedObject private var c = SpeechController.shared

    @State private var name = ""
    @State private var pickedURL: URL?
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stimmen verwalten").font(.title3).bold()

            GroupBox("Eigene Stimmen") {
                if c.customVoices.isEmpty {
                    Text("Noch keine eigene Stimme.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(c.customVoices) { voice in
                        HStack {
                            Image(systemName: c.selectedVoice == voice.id ? "checkmark.circle.fill" : "person.wave.2")
                            Text(voice.name)
                            Spacer()
                            Button("Wählen") { c.selectedVoice = voice.id; c.save() }
                                .buttonStyle(.link)
                            Button(role: .destructive) {
                                Task { await c.deleteVoice(voice.id) }
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            GroupBox("Neue Stimme aus Aufnahme") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Audio wählen …") { pickFile() }
                        Text(pickedURL?.lastPathComponent ?? "keine Datei")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    TextField("Name", text: $name)
                    HStack {
                        Button(busy ? "Importiere …" : "Importieren") { startImport() }
                            .disabled(busy || pickedURL == nil || name.isEmpty)
                        if !message.isEmpty {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Button {
                c.speak(text: "Hallo, dies ist eine Hörprobe von pappagei.")
            } label: {
                Label("Hörprobe der gewählten Stimme", systemImage: "play.circle")
            }
            .disabled(c.selectedVoice.isEmpty)

            Text("Tipp: ~5-10s klar gesprochen, ein Sprecher, wenig Störgeräusch. WAV oder mp3. Kein Transkript nötig — Qwen klont direkt aus dem Audio.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 380)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio, .audio]
        if panel.runModal() == .OK, let url = panel.url {
            pickedURL = url
            if name.isEmpty {
                name = url.deletingPathExtension().lastPathComponent
            }
        }
    }

    private func startImport() {
        guard let url = pickedURL else { return }
        busy = true
        message = ""
        Task {
            let ok = await c.importVoice(name: name, path: url.path, transcript: nil, speaker: "Chelsie")
            busy = false
            message = ok ? "Importiert und ausgewählt." : "Import fehlgeschlagen."
            if ok {
                pickedURL = nil
                name = ""
            }
        }
    }
}
