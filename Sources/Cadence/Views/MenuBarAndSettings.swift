import AppKit
import CadenceCore
import SwiftUI

/// Menüleisten-Menü: Status, Sprecher setzen und Marker – ohne das Hauptfenster zu öffnen.
struct MenuBarView: View {
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var navigation: Navigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if recorder.isRecording, let session = recorder.session {
            Text("● Aufnahme läuft – \(TimeFormat.clock(recorder.elapsed))")
            Divider()
            Section("Wer spricht?") {
                ForEach(Array(session.hotkeyPeople.enumerated()), id: \.element.id) { index, person in
                    Button {
                        recorder.setCurrentSpeaker(person.id)
                    } label: {
                        Text((recorder.currentSpeakerID == person.id ? "✓ " : "") + "\(index + 1)  \(person.name)")
                    }
                }
                Button((recorder.currentSpeakerID == nil ? "✓ " : "") + "0  Unbekannt") { recorder.setCurrentSpeaker(nil) }
            }
            Divider()
            Button("⭐️ Wichtige Stelle") { recorder.addMarker(.highlight) }
            Button("✅ Aufgabe") { recorder.addMarker(.todo) }
            Button("⚖️ Entscheidung") { recorder.addMarker(.decision) }
            Divider()
            Button("Aufnahme beenden") { Task { await recorder.stop() } }
        } else if case .finishing(let status) = recorder.phase {
            Text(status)
        } else {
            Button("Neue Aufnahme …") {
                navigation.selection = .newRecording
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        Divider()
        Button("Cadence öffnen") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Beenden") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var models: ModelManager
    @AppStorage(SettingsKey.ownerName) private var ownerName = Defaults.ownerName
    @AppStorage(SettingsKey.ownPartyName) private var ownPartyName = "Wir"
    @AppStorage(SettingsKey.otherPartyName) private var otherPartyName = "Kunde"
    @AppStorage(SettingsKey.model) private var model = WhisperModelOption.largeTurbo.rawValue
    @AppStorage(SettingsKey.language) private var language = LanguageOption.german.rawValue
    @AppStorage(SettingsKey.storagePath) private var storagePath = ""
    @AppStorage(SettingsKey.saveAudio) private var saveAudio = true
    @AppStorage(SettingsKey.voiceProcessing) private var voiceProcessing = false
    @AppStorage(SettingsKey.consentReminder) private var consentReminder = true
    @AppStorage(SettingsKey.runDiarization) private var runDiarization = true
    @AppStorage(SettingsKey.globalHotkeys) private var globalHotkeys = true

    var body: some View {
        TabView {
            Form {
                TextField("Dein Name", text: $ownerName)
                TextField("Eigene Partei (Standard)", text: $ownPartyName)
                TextField("Gegenseite (Standard)", text: $otherPartyName)
                Toggle("Vor jeder Aufnahme an die Einwilligung erinnern", isOn: $consentReminder)
                Toggle("Systemweite Tastenkürzel (⌃⌥ 0–9, M, A, E, N, R)", isOn: $globalHotkeys)
                    .onChange(of: globalHotkeys) { _, enabled in
                        enabled ? GlobalHotkeys.shared.register() : GlobalHotkeys.shared.unregister()
                    }
            }
            .tabItem { Label("Allgemein", systemImage: "gearshape") }

            Form {
                Picker("Sprachmodell", selection: $model) {
                    ForEach(WhisperModelOption.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .onChange(of: model) { _, _ in models.reload() }
                LabeledContent("Status") {
                    HStack {
                        switch models.status {
                        case .ready: Label("Bereit", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .downloading(let p): Text("Wird geladen – \(Int(p * 100)) %")
                        case .loading, .warmingUp: Text("Wird vorbereitet …")
                        case .failed(let message): Text(message).foregroundStyle(.red)
                        case .idle: Text("Nicht geladen")
                        }
                        Spacer()
                        if !models.status.isWorking {
                            Button(models.isReady ? "Neu laden" : "Laden") { models.reload() }
                        }
                    }
                }
                LabeledContent("Modellordner") {
                    Button("Im Finder zeigen") { NSWorkspace.shared.open(ModelStorage.folder) }
                }
                Picker("Sprache", selection: $language) {
                    ForEach(LanguageOption.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                Toggle("Stimmen nach dem Gespräch automatisch trennen (Diarization)", isOn: $runDiarization)
                Toggle("Echounterdrückung fürs Mikrofon (ohne Kopfhörer)", isOn: $voiceProcessing)
                Text("Alles läuft lokal. Modelle werden einmalig heruntergeladen und danach offline genutzt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tabItem { Label("Transkription", systemImage: "text.bubble") }

            Form {
                Toggle("Audio-Aufnahme behalten (M4A)", isOn: $saveAudio)
                LabeledContent("Speicherort") {
                    HStack {
                        Text(store.rootFolder.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Ändern …", action: chooseFolder)
                        if !storagePath.isEmpty {
                            Button("Standard") {
                                storagePath = ""
                                store.reload()
                            }
                        }
                    }
                }
                Text("Ohne Audio werden nur Transkript und Protokoll gespeichert. Die Audiodateien werden nach der Sprechertrennung gelöscht.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tabItem { Label("Speichern", systemImage: "externaldrive") }

            VoiceProfilesSettings()
                .tabItem { Label("Stimmen", systemImage: "waveform") }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Auswählen"
        if panel.runModal() == .OK, let url = panel.url {
            storagePath = url.path
            store.reload()
        }
    }
}

/// Gespeicherte Stimmprofile ansehen und löschen.
private struct VoiceProfilesSettings: View {
    @EnvironmentObject private var voices: VoiceProfileStore
    @AppStorage(SettingsKey.voiceRecognition) private var voiceRecognition = true
    @State private var confirmDeleteAll = false

    var body: some View {
        Form {
            Toggle("Stimmen merken und in künftigen Gesprächen wiedererkennen", isOn: $voiceRecognition)
            Text("Sobald du einer Stimme eine Person zuordnest (live oder danach), speichert Cadence einen Stimm-Fingerabdruck – nur lokal auf diesem Mac. Nach dem nächsten Gespräch trägt Cadence bekannte Stimmen automatisch ein. Je öfter jemand dabei war, desto zuverlässiger.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Section("Bekannte Stimmen") {
                if voices.profiles.isEmpty {
                    Text("Noch keine. Ordne nach einem Gespräch die Stimmen zu, dann erscheinen sie hier.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(voices.profiles.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }) { profile in
                        HStack {
                            Avatar(name: profile.name, color: Theme.accent, size: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.name)
                                Text([profile.partyName, "\(profile.sessionCount) \(profile.sessionCount == 1 ? "Gespräch" : "Gespräche")"]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                voices.delete(profile.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Stimmprofil löschen")
                        }
                    }
                    Button("Alle Stimmprofile löschen", role: .destructive) { confirmDeleteAll = true }
                }
            }
        }
        .confirmationDialog("Alle Stimmprofile löschen?", isPresented: $confirmDeleteAll) {
            Button("Alle löschen", role: .destructive) { voices.deleteAll() }
        } message: {
            Text("Gespräche und Transkripte bleiben erhalten.")
        }
    }
}
