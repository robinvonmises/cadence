import AVFoundation
import CadenceCore
import SwiftUI

struct NewRecordingView: View {
    @EnvironmentObject private var recorder: RecordingController
    @AppStorage(SettingsKey.consentReminder) private var consentReminder = true
    @AppStorage(SettingsKey.consentMessage) private var consentMessage = Defaults.consentMessage
    @AppStorage(SettingsKey.ownPartyName) private var ownPartyName = "Wir"
    @AppStorage(SettingsKey.otherPartyName) private var otherPartyName = "Kunde"

    @State private var title = ""
    @State private var apps: [MeetingApp] = []
    @State private var target: SystemAudioTarget = .allSystemAudio
    @State private var showConsent = false
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("Titel, z. B. „Kickoff mit Kunde X“", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .font(.title3)
                            .onSubmit(startTapped)

                        Picker("Gegenseite aufnehmen von", selection: $target) {
                            Text("Gesamter Systemton (empfohlen)").tag(SystemAudioTarget.allSystemAudio)
                            if !apps.isEmpty { Divider() }
                            ForEach(apps) { app in
                                Text(app.name).tag(SystemAudioTarget.app(bundleID: app.bundleID, name: app.name))
                            }
                        }
                        .onAppear(perform: refreshApps)

                        HStack(spacing: 16) {
                            TextField("Eigene Partei", text: $ownPartyName).frame(width: 160)
                            TextField("Gegenseite", text: $otherPartyName).frame(width: 160)
                            Text("Weitere Parteien kannst du während des Gesprächs hinzufügen.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Button(action: startTapped) {
                                Label(recorder.phase == .preparing ? "Startet …" : "Aufnahme starten", systemImage: "record.circle")
                                    .frame(minWidth: 180)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                            .disabled(recorder.isBusy)

                            Toggle("Einwilligung abfragen", isOn: $consentReminder)
                                .toggleStyle(.checkbox)
                                .padding(.leading, 12)
                        }
                    }
                    .padding(8)
                } label: {
                    Label("Neues Gespräch", systemImage: "waveform.badge.mic")
                }

                permissions
                HotkeyCheatSheet()
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .sheet(isPresented: $showConsent) {
            ConsentSheet(message: $consentMessage) { confirmed in
                showConsent = false
                if confirmed { start(consent: true) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cadence").font(.largeTitle.bold())
            Text("Nimmt dein Mikrofon und den Ton deiner Meeting-App getrennt auf und transkribiert alles lokal auf diesem Mac – inklusive Sprecherzuordnung.")
                .foregroundStyle(.secondary)
        }
    }

    private var permissions: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: micStatus == .authorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(micStatus == .authorized ? .green : .orange)
                    Text("Mikrofon")
                    Spacer()
                    if micStatus != .authorized {
                        Button("Freigeben") {
                            Task {
                                _ = await MicrophoneCapture.requestPermission()
                                micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                                if micStatus == .denied { PrivacyPane.microphone() }
                            }
                        }
                    }
                }
                HStack {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("Systemaudio: macOS fragt beim ersten Start einer Aufnahme nach „Systemaudioaufnahme“.")
                    Spacer()
                    Button("Einstellungen öffnen") { PrivacyPane.systemAudio() }
                }
                Text("Tipp: Mit Kopfhörern wird die Gegenseite nicht zusätzlich über dein Mikrofon aufgenommen. Ohne Kopfhörer hilft die Echounterdrückung in den Einstellungen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            Label("Berechtigungen", systemImage: "lock.shield")
        }
    }

    private func refreshApps() {
        apps = AudioSourceCatalog.runningApps()
    }

    private func startTapped() {
        guard !recorder.isBusy else { return }
        if consentReminder {
            showConsent = true
        } else {
            start(consent: false)
        }
    }

    private func start(consent: Bool) {
        Task { await recorder.start(title: title, target: target, consentConfirmed: consent) }
    }
}

/// DSGVO-Erinnerung: Vor der Aufnahme alle Beteiligten informieren und Einwilligung einholen.
struct ConsentSheet: View {
    @Binding var message: String
    let completion: (Bool) -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Sind alle mit der Aufzeichnung einverstanden?", systemImage: "hand.raised.fill")
                .font(.title2.bold())
            Text("In Deutschland ist das Aufzeichnen nicht öffentlich gesprochener Worte ohne Zustimmung strafbar (§ 201 StGB), und die DSGVO verlangt eine Rechtsgrundlage. Hol dir vorab das Einverständnis aller Beteiligten – z. B. mit dieser Nachricht im Meeting-Chat:")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            TextEditor(text: $message)
                .font(.body)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Kopiert" : "Nachricht kopieren", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Spacer()
                Button("Abbrechen") { completion(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Alle sind einverstanden – Aufnahme starten") { completion(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            Text("Die Bestätigung wird mit Zeitstempel im Protokoll vermerkt.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 560)
    }
}

struct HotkeyCheatSheet: View {
    var body: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("\(GlobalHotkeys.modifierSymbol)1 … 9", "Diese Person spricht gerade (Reihenfolge der Teilnehmerliste)")
                row("\(GlobalHotkeys.modifierSymbol)0", "Sprecher unbekannt")
                row("\(GlobalHotkeys.modifierSymbol)N", "Cadence nach vorn holen und neuen Namen eintippen")
                row("\(GlobalHotkeys.modifierSymbol)M / A / E", "Wichtige Stelle / Aufgabe / Entscheidung markieren")
                row("\(GlobalHotkeys.modifierSymbol)R", "Aufnahme beenden")
            }
            .padding(6)
        } label: {
            Label("Tastenkürzel – funktionieren auch, während Teams im Vordergrund ist", systemImage: "keyboard")
        }
    }

    private func row(_ keys: String, _ text: String) -> some View {
        GridRow {
            Text(keys).font(.body.monospaced()).foregroundStyle(.primary)
            Text(text).foregroundStyle(.secondary)
        }
    }
}
