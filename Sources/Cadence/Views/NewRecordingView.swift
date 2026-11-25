import AVFoundation
import CadenceCore
import SwiftUI

/// Startbildschirm: Titel, Quelle, Parteien – und ein großer Aufnahmeknopf.
struct NewRecordingView: View {
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var models: ModelManager
    @AppStorage(SettingsKey.consentReminder) private var consentReminder = true
    @AppStorage(SettingsKey.consentMessage) private var consentMessage = Defaults.consentMessage
    @AppStorage(SettingsKey.ownPartyName) private var ownPartyName = "Wir"
    @AppStorage(SettingsKey.otherPartyName) private var otherPartyName = "Kunde"

    @State private var title = ""
    @State private var apps: [MeetingApp] = []
    @State private var target: SystemAudioTarget = .allSystemAudio
    @State private var showConsent = false
    @State private var showShortcuts = false
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var hoveringRecord = false

    private var meetingApps: [MeetingApp] { apps.filter(\.isKnownMeetingApp) }
    private var otherApps: [MeetingApp] { apps.filter { !$0.isKnownMeetingApp } }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                hero
                ModelStatusBanner()
                if micStatus != .authorized { permissionBanner }

                VStack(alignment: .leading, spacing: 22) {
                    titleField
                    sourcePicker
                    partiesRow
                }
                .card(padding: 22)

                recordButton

                Button {
                    showShortcuts.toggle()
                } label: {
                    Label("Tastenkürzel", systemImage: "keyboard")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .popover(isPresented: $showShortcuts, arrowEdge: .bottom) {
                    HotkeyCheatSheet().padding(20).frame(width: 420)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 36)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(backgroundGlow)
        .onAppear {
            apps = AudioSourceCatalog.runningApps()
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        .sheet(isPresented: $showConsent) {
            ConsentSheet(message: $consentMessage) { confirmed in
                showConsent = false
                if confirmed { start(consent: true) }
            }
        }
    }

    // MARK: Abschnitte

    private var backgroundGlow: some View {
        ZStack {
            Circle().fill(Theme.violet.opacity(0.12)).frame(width: 520).blur(radius: 120).offset(x: -180, y: -220)
            Circle().fill(Theme.pink.opacity(0.10)).frame(width: 420).blur(radius: 120).offset(x: 220, y: -120)
        }
        .allowsHitTesting(false)
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .shadow(color: Theme.violet.opacity(0.35), radius: 16, y: 8)
            Text("Bereit fürs nächste Gespräch")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Cadence hört mit, schreibt mit und merkt sich, wer was gesagt hat – alles lokal auf deinem Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Worum geht's?").sectionTitle()
            TextField("z. B. Kickoff mit Kunde X", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                .onSubmit(startTapped)
        }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Ton aufnehmen von").sectionTitle()
                Spacer()
                Button {
                    apps = AudioSourceCatalog.runningApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Liste der laufenden Apps aktualisieren")
            }
            FlowLayout(spacing: 8) {
                SourceChip(title: "Alle Apps", systemImage: "square.stack.3d.up.fill", icon: nil,
                           isSelected: target == .allSystemAudio) {
                    target = .allSystemAudio
                }
                ForEach(meetingApps) { app in
                    let appTarget = SystemAudioTarget.app(bundleID: app.bundleID, name: app.name)
                    SourceChip(title: app.name, systemImage: nil, icon: app.icon, isSelected: target == appTarget) {
                        target = appTarget
                    }
                }
                if !otherApps.isEmpty {
                    Menu {
                        ForEach(otherApps) { app in
                            Button(app.name) { target = .app(bundleID: app.bundleID, name: app.name) }
                        }
                    } label: {
                        Label(otherAppSelectedName ?? "Andere App …", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(otherAppSelectedName != nil ? Theme.accent.opacity(0.15) : Color.clear, in: Capsule())
                }
            }
            Text(target == .allSystemAudio
                 ? "Empfohlen: funktioniert mit Teams, Zoom, Meet, Webex und jedem Browser."
                 : "Nur der Ton von \(target.label) wird aufgenommen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var otherAppSelectedName: String? {
        if case .app(let id, let name) = target, otherApps.contains(where: { $0.bundleID == id }) { return name }
        return nil
    }

    private var partiesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wer ist dabei?").sectionTitle()
            HStack(spacing: 12) {
                PartyField(color: PartyColor.blue.color, placeholder: "Eigene Firma", text: $ownPartyName)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.tertiary)
                PartyField(color: PartyColor.orange.color, placeholder: "Gegenseite", text: $otherPartyName)
            }
            Text("Weitere Parteien und die einzelnen Personen fügst du während des Gesprächs hinzu.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var recordButton: some View {
        VStack(spacing: 12) {
            Button(action: startTapped) {
                ZStack {
                    Circle()
                        .fill(Theme.record.opacity(0.18))
                        .frame(width: 112, height: 112)
                        .scaleEffect(hoveringRecord ? 1.08 : 1)
                    Circle()
                        .fill(Theme.recordGradient)
                        .frame(width: 84, height: 84)
                        .shadow(color: Theme.record.opacity(0.45), radius: 14, y: 6)
                    if recorder.phase == .preparing {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .animation(.spring(duration: 0.3), value: hoveringRecord)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(recorder.isBusy)
            .onHover { hoveringRecord = $0 }
            .help("Aufnahme starten (⏎)")

            Text(recorder.phase == .preparing ? "Startet …" : "Aufnahme starten")
                .font(.system(.headline, design: .rounded))
            Toggle("Vorher an die Einwilligung erinnern", isOn: $consentReminder)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionBanner: some View {
        Banner(kind: .warning, title: "Cadence braucht Zugriff auf dein Mikrofon",
               message: "Damit deine eigenen Beiträge im Transkript landen.") {
            Button("Freigeben") {
                Task {
                    _ = await MicrophoneCapture.requestPermission()
                    micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                    if micStatus == .denied { PrivacyPane.microphone() }
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Aktionen

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

private struct SourceChip: View {
    let title: String
    let systemImage: String?
    let icon: NSImage?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                } else if let systemImage {
                    Image(systemName: systemImage).frame(width: 18, height: 18)
                }
                Text(title).lineLimit(1)
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? Theme.accent.opacity(0.15) : Color.primary.opacity(0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct PartyField: View {
    let color: Color
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            TextField(placeholder, text: $text).textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// DSGVO-Erinnerung: Vor der Aufnahme alle Beteiligten informieren und Einwilligung einholen.
struct ConsentSheet: View {
    @Binding var message: String
    let completion: (Bool) -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.title)
                    .foregroundStyle(Theme.gradient)
                Text("Sind alle einverstanden?")
                    .font(.system(.title2, design: .rounded).bold())
            }
            Text("Gespräche ohne Zustimmung aufzuzeichnen ist in Deutschland strafbar (§ 201 StGB), und die DSGVO verlangt eine Rechtsgrundlage. Frag kurz in die Runde – zum Beispiel mit dieser Nachricht im Meeting-Chat:")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            TextEditor(text: $message)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 110)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
                copied = true
            } label: {
                Label(copied ? "Kopiert – jetzt im Chat einfügen" : "Nachricht kopieren", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            Divider()
            HStack {
                Text("Die Bestätigung wird mit Zeitstempel im Protokoll vermerkt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Abbrechen") { completion(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Alle sind einverstanden") { completion(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

struct HotkeyCheatSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tastenkürzel").font(.headline)
            Text("Funktionieren überall – auch wenn Teams im Vordergrund ist.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                row("⌃⌥ 1 … 9", "Diese Person spricht gerade")
                row("⌃⌥ 0", "Sprecher unbekannt")
                row("⌃⌥ N", "Neuen Namen eintippen")
                row("⌃⌥ M", "Wichtige Stelle markieren")
                row("⌃⌥ A", "Aufgabe markieren")
                row("⌃⌥ E", "Entscheidung markieren")
                row("⌃⌥ R", "Aufnahme beenden")
            }
        }
    }

    private func row(_ keys: String, _ text: String) -> some View {
        GridRow {
            Text(keys)
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            Text(text).foregroundStyle(.secondary)
        }
    }
}
