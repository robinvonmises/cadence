import AVFoundation
import CadenceCore
import SwiftUI

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
    @State private var showHotkeys = false
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var hovering = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                hero
                setupCard
                readiness
                hotkeys
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            refreshApps()
            titleFocused = true
        }
        .sheet(isPresented: $showConsent) {
            ConsentSheet(message: $consentMessage) { confirmed in
                showConsent = false
                if confirmed { start(consent: true) }
            }
        }
    }

    // MARK: Kopf mit Aufnahmeknopf

    private var hero: some View {
        VStack(spacing: 16) {
            Button(action: startTapped) {
                ZStack {
                    Circle()
                        .fill(Brand.record.opacity(hovering ? 0.22 : 0.14))
                        .frame(width: 112, height: 112)
                    Circle()
                        .fill(Brand.recordGradient)
                        .frame(width: 80, height: 80)
                        .shadow(color: Brand.record.opacity(0.45), radius: hovering ? 18 : 10, y: 4)
                    if recorder.phase == .preparing {
                        ProgressView().controlSize(.regular).tint(.white)
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .scaleEffect(hovering ? 1.04 : 1)
                .animation(.spring(duration: 0.3), value: hovering)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .disabled(recorder.isBusy)
            .keyboardShortcut(.defaultAction)
            .help("Aufnahme starten (⏎)")

            VStack(spacing: 4) {
                Text(recorder.phase == .preparing ? "Aufnahme startet …" : "Neues Gespräch aufnehmen")
                    .font(.title2.weight(.bold))
                Text("Mikrofon und Meeting-Ton werden getrennt aufgezeichnet und lokal transkribiert.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 8)
    }

    // MARK: Einstellungen fürs Gespräch

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Titel")
                TextField("z. B. Kickoff mit Kunde X", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(titleFocused ? Brand.violet.opacity(0.6) : .primary.opacity(0.08), lineWidth: titleFocused ? 2 : 1))
                    .focused($titleFocused)
                    .onSubmit(startTapped)
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Ton der Gegenseite")
                HStack(spacing: 10) {
                    SourceOption(
                        title: "Gesamter Systemton",
                        subtitle: "Empfohlen – funktioniert mit jeder App",
                        systemImage: "speaker.wave.2.fill",
                        selected: target == .allSystemAudio
                    ) { target = .allSystemAudio }

                    SourceOption(
                        title: appTargetName ?? "Nur eine App",
                        subtitle: apps.isEmpty ? "Keine Meeting-App erkannt" : "Teams, Zoom, Webex …",
                        systemImage: "app.badge",
                        selected: target != .allSystemAudio
                    ) {
                        if target == .allSystemAudio, let first = apps.first {
                            target = .app(bundleID: first.bundleID, name: first.name)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if !apps.isEmpty {
                            Menu {
                                ForEach(apps) { app in
                                    Button(app.name) { target = .app(bundleID: app.bundleID, name: app.name) }
                                }
                                Divider()
                                Button("Liste aktualisieren", action: refreshApps)
                            } label: {
                                Image(systemName: "chevron.down.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .padding(8)
                        }
                    }
                    .disabled(apps.isEmpty)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Parteien")
                HStack(spacing: 10) {
                    PartyField(color: .blue, placeholder: "Eigene Partei", text: $ownPartyName)
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(.tertiary)
                    PartyField(color: .orange, placeholder: "Gegenseite", text: $otherPartyName)
                }
                Text("Weitere Parteien und Personen fügst du während des Gesprächs hinzu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Toggle(isOn: $consentReminder) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Vorher Einwilligung einholen")
                        Text("Zeigt einen Hinweistext für den Meeting-Chat").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Spacer()
                Button(action: startTapped) {
                    Label("Aufnahme starten", systemImage: "record.circle")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.record)
                .controlSize(.large)
                .disabled(recorder.isBusy)
            }
        }
        .card(padding: 20)
    }

    private var appTargetName: String? {
        if case .app(_, let name) = target { return name }
        return nil
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    // MARK: Bereitschaft

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Bereit für die Aufnahme?", systemImage: "checklist")
            VStack(spacing: 0) {
                ReadinessRow(
                    systemImage: "mic.fill",
                    title: "Mikrofon",
                    detail: micStatus == .authorized ? "Freigegeben" : "Noch nicht freigegeben",
                    ok: micStatus == .authorized
                ) {
                    if micStatus != .authorized {
                        Button("Freigeben") {
                            Task {
                                _ = await MicrophoneCapture.requestPermission()
                                micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                                if micStatus == .denied { PrivacyPane.microphone() }
                            }
                        }
                        .controlSize(.small)
                    }
                }
                Divider().padding(.leading, 44)
                ReadinessRow(
                    systemImage: "speaker.wave.2.fill",
                    title: "Systemaudio",
                    detail: "macOS fragt beim ersten Start nach „Systemaudioaufnahme“",
                    ok: nil
                ) {
                    Button("Einstellungen") { PrivacyPane.systemAudio() }
                        .controlSize(.small)
                }
                Divider().padding(.leading, 44)
                ReadinessRow(
                    systemImage: "brain.head.profile",
                    title: "Sprachmodell",
                    detail: models.status == .ready ? "Läuft lokal auf diesem Mac" : "Wird automatisch geladen – du kannst trotzdem schon aufnehmen",
                    ok: models.status == .ready ? true : nil
                ) {
                    if models.status != .ready {
                        ModelStatusView(compact: true)
                    }
                }
            }
            if case .downloading = models.status {
                ModelStatusView()
                    .padding(.top, 4)
            }
            Label("Mit Kopfhörern landet die Gegenseite nicht zusätzlich in deinem Mikrofon. Ohne Kopfhörer hilft die Echounterdrückung in den Einstellungen.", systemImage: "headphones")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card(padding: 18)
    }

    private var hotkeys: some View {
        DisclosureGroup(isExpanded: $showHotkeys) {
            HotkeyCheatSheet()
                .padding(.top, 10)
        } label: {
            SectionTitle(title: "Tastenkürzel", systemImage: "keyboard", subtitle: "Funktionieren auch, während Teams im Vordergrund ist")
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { showHotkeys.toggle() } }
        }
        .card(padding: 18)
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

/// Auswahlkarte für die Tonquelle.
private struct SourceOption: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? .white : Brand.violet)
                    .frame(width: 32, height: 32)
                    .background(selected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Brand.violet.opacity(0.1)),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 24)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(selected ? Brand.violet.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(selected ? Brand.violet.opacity(0.7) : .primary.opacity(0.1), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
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
            Circle().fill(color).frame(width: 9, height: 9)
            TextField(placeholder, text: $text).textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }
}

private struct ReadinessRow<Accessory: View>: View {
    let systemImage: String
    let title: String
    let detail: String
    let ok: Bool?
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.violet)
                .frame(width: 30, height: 30)
                .background(Brand.violet.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.callout.weight(.medium))
                    if ok == true {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    } else if ok == false {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.caption)
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            accessory()
        }
        .padding(.vertical, 8)
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
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sind alle einverstanden?").font(.title2.bold())
                    Text("Kurz fragen, dann geht’s los.").foregroundStyle(.secondary)
                }
            }
            Text("Das Aufzeichnen nicht öffentlich gesprochener Worte ohne Zustimmung ist strafbar (§ 201 StGB), und die DSGVO verlangt eine Rechtsgrundlage. Schick z. B. diese Nachricht in den Meeting-Chat:")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            TextEditor(text: $message)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 110)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.08)))
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
                Button("Alle sind einverstanden – starten") { completion(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.record)
            }
            Text("Die Bestätigung wird mit Zeitstempel im Protokoll vermerkt.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 580)
    }
}

struct HotkeyCheatSheet: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            row("\(GlobalHotkeys.modifierSymbol)1 … 9", "Diese Person spricht gerade (Reihenfolge der Teilnehmer)")
            row("\(GlobalHotkeys.modifierSymbol)0", "Sprecher unbekannt")
            row("\(GlobalHotkeys.modifierSymbol)N", "Cadence nach vorn holen und neuen Namen eintippen")
            row("\(GlobalHotkeys.modifierSymbol)M / A / E", "Wichtige Stelle / Aufgabe / Entscheidung markieren")
            row("\(GlobalHotkeys.modifierSymbol)R", "Aufnahme beenden")
        }
    }

    private func row(_ keys: String, _ text: String) -> some View {
        GridRow {
            Text(keys)
                .font(.callout.monospaced().weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }
}
