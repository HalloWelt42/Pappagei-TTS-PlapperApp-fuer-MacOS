import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct VoiceManagerView: View {
    @ObservedObject private var c = SpeechController.shared

    @State private var name = ""
    @State private var transcript = ""
    @State private var speaker = "vivian"
    @State private var pickedURL: URL?
    @State private var busy = false
    @State private var message = ""

    private let cloneSpeakers = [
        "serena", "vivian", "uncle_fu", "ryan", "aiden",
        "ono_anna", "sohee", "eric", "dylan",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stimmen verwalten").font(.title3).bold()

            GroupBox("Eigene Stimmen") {
                if c.customVoices.isEmpty {
                    Text("Noch keine eigene Stimme importiert.")
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
                    TextField("Transkript des Clips (optional, verbessert die Qualität)",
                              text: $transcript, axis: .vertical)
                        .lineLimit(1...3)
                    Picker("Basis-Sprecher", selection: $speaker) {
                        ForEach(cloneSpeakers, id: \.self) { Text($0).tag($0) }
                    }
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

            Text("Tipp: ~5-7s, klar gesprochen, ein Sprecher, wenig Störgeräusch. WAV bevorzugt; mp3/m4a meist auch ok.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 400)
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
            let ok = await c.importVoice(
                name: name,
                path: url.path,
                transcript: transcript.isEmpty ? nil : transcript,
                speaker: speaker
            )
            busy = false
            message = ok ? "Importiert und ausgewählt." : "Import fehlgeschlagen."
            if ok {
                pickedURL = nil
                name = ""
                transcript = ""
            }
        }
    }
}
