import AVFoundation
import CadenceCore
import SwiftUI

/// Startbildschirm ohne Scrollen: links Gespräch & Aufnahme, rechts die Teilnehmer.
struct NewRecordingView: View {
    @EnvironmentObject private var recorder: RecordingController
    @AppStorage(SettingsKey.consentReminder) private var consentReminder = true
    @AppStorage(SettingsKey.consentMessage) private var consentMessage = Defaults.consentMessage
    @AppStorage(SettingsKey.language) private var language = LanguageOption.german.rawValue
    @AppStorage(SettingsKey.ownerName) private var ownerName = Defaults.ownerName
    @AppStorage(SettingsKey.recordMicrophone) private var recordMicrophone = true
    @AppStorage(SettingsKey.microphoneDevice) private var microphoneDevice = ""
    @State private var inputDevices: [InputDevice] = []

    @State private var apps: [MeetingApp] = []
    @State private var target: SystemAudioTarget = .allSystemAudio
    @State private var showConsent = false
    @State private var showShortcuts = false
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var hoveringRecord = false

    private var meetingApps: [MeetingApp] { apps.filter(\.isKnownMeetingApp) }
    private var otherApps: [MeetingApp] { apps.filter { !$0.isKnownMeetingApp } }

    var body: some View {
        // GeometryReader meldet als Mindestgröße 0. Ohne ihn fragt macOS das Layout mit Breite 0 ab,
        // umbrechende Texte werden dann tausende Punkte hoch und das Fenster rutscht ins Leere.
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
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

    private var content: some View {
        VStack(spacing: 18) {
            hero
            ModelStatusBanner()
            if recordMicrophone, micStatus != .authorized { permissionBanner }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 20) {
                    titleField
                    sourcePicker
                    microphonePicker
                    languagePicker
                    Spacer(minLength: 0)
                    recordButton
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .card(padding: 20)

                ParticipantSetup(draft: $recorder.draft, ownerName: ownerName)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .card(padding: 20)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(24)
        .frame(maxWidth: 1100, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: Abschnitte

    private var backgroundGlow: some View {
        ZStack {
            Circle().fill(Theme.violet.opacity(0.12)).frame(width: 520).blur(radius: 120).offset(x: -260, y: -220)
            Circle().fill(Theme.pink.opacity(0.10)).frame(width: 420).blur(radius: 120).offset(x: 280, y: -160)
        }
        .allowsHitTesting(false)
    }

    private var hero: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
                .shadow(color: Theme.violet.opacity(0.35), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bereit fürs nächste Gespräch")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Teilnehmer vorbereiten, starten, im Gespräch per Klick oder ⌃⌥ + Zahl zuordnen. Alles bleibt lokal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showShortcuts.toggle()
            } label: {
                Label("Tastenkürzel", systemImage: "keyboard")
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $showShortcuts, arrowEdge: .bottom) {
                HotkeyCheatSheet().padding(20).frame(width: 420)
            }
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Worum geht's?").sectionTitle()
            TextField("z. B. Kickoff mit Kunde X", text: $recorder.draft.title)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
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
                SourceChip(title: String(localized: "Alle Apps"), systemImage: "square.stack.3d.up.fill", icon: nil,
                           isSelected: target == .allSystemAudio) {
                    target = .allSystemAudio
                }
                ForEach(meetingApps.prefix(4)) { app in
                    let appTarget = SystemAudioTarget.app(bundleID: app.bundleID, name: app.name)
                    SourceChip(title: app.name, systemImage: nil, icon: app.icon, isSelected: target == appTarget) {
                        target = appTarget
                    }
                }
                let more = Array(meetingApps.dropFirst(4)) + otherApps
                if !more.isEmpty {
                    Menu {
                        ForEach(more) { app in
                            Button(app.name) { target = .app(bundleID: app.bundleID, name: app.name) }
                        }
                    } label: {
                        Label(otherAppSelectedName(in: more) ?? "Andere App …", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(otherAppSelectedName(in: more) != nil ? Theme.accent.opacity(0.15) : Color.clear, in: Capsule())
                }
            }
            Text(target == .allSystemAudio
                 ? "Empfohlen: funktioniert mit Teams, Zoom, Meet, Webex und jedem Browser."
                 : "Nur der Ton von \(target.label) wird aufgenommen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func otherAppSelectedName(in list: [MeetingApp]) -> String? {
        if case .app(let id, let name) = target, list.contains(where: { $0.bundleID == id }) { return name }
        return nil
    }

    /// Eigenes Mikrofon an/aus und Eingangsgerät – aus z. B. für Podcasts oder Videos.
    private var microphonePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mikrofon").sectionTitle()
            HStack(spacing: 12) {
                Toggle("Mein Mikrofon aufnehmen", isOn: $recordMicrophone)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer(minLength: 8)
                if recordMicrophone {
                    Picker("Eingang", selection: $microphoneDevice) {
                        Text("Systemstandard").tag("")
                        ForEach(inputDevices) { Text($0.name).tag($0.uid) }
                        if !microphoneDevice.isEmpty, !inputDevices.contains(where: { $0.uid == microphoneDevice }) {
                            Text("Nicht verbunden").tag(microphoneDevice)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Text(recordMicrophone
                 ? "Deine Stimme wird als eigene Spur aufgenommen und dir zugeordnet."
                 : "Dein Mikrofon startet stumm, z. B. für Podcasts oder Videos. Im Gespräch schaltest du es mit einem Klick ein.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { inputDevices = InputDevices.all() }
    }

    private var languagePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sprache").sectionTitle()
            Picker("Sprache", selection: $language) {
                Text("Deutsch").tag(LanguageOption.german.rawValue)
                Text("Englisch").tag(LanguageOption.english.rawValue)
                Text("Automatisch").tag(LanguageOption.auto.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("„Automatisch“ erkennt die Sprache selbst, gut für gemischte Runden.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var recordButton: some View {
        HStack(spacing: 18) {
            Button(action: startTapped) {
                ZStack {
                    Circle()
                        .fill(Theme.record.opacity(0.18))
                        .frame(width: 92, height: 92)
                        .scaleEffect(hoveringRecord ? 1.08 : 1)
                    Circle()
                        .fill(Theme.recordGradient)
                        .frame(width: 70, height: 70)
                        .shadow(color: Theme.record.opacity(0.45), radius: 12, y: 5)
                    if recorder.phase == .preparing {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .animation(.spring(duration: 0.3), value: hoveringRecord)
            }
            .buttonStyle(.plain)
            // ⌘⏎ statt ⏎, damit ⏎ in den Namensfeldern nicht versehentlich die Aufnahme startet.
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(recorder.isBusy)
            .onHover { hoveringRecord = $0 }
            .help("Aufnahme starten (⌘⏎)")

            VStack(alignment: .leading, spacing: 6) {
                Text(recorder.phase == .preparing ? "Startet …" : "Aufnahme starten")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                Text("Klicken oder ⌘⏎")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Vorher an die Einwilligung erinnern", isOn: $consentReminder)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var permissionBanner: some View {
        Banner(kind: .warning, title: String(localized: "Cadence braucht Zugriff auf dein Mikrofon"),
               message: String(localized: "Damit deine eigenen Beiträge im Transkript landen.")) {
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
        let draft = recorder.draft
        Task { await recorder.start(draft: draft, target: target, consentConfirmed: consent) }
    }
}

/// Teilnehmer vor dem Gespräch anlegen: je Partei eine Karte mit Personen und Ziffern 1–9.
private struct ParticipantSetup: View {
    @Binding var draft: MeetingDraft
    let ownerName: String
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var voices: VoiceProfileStore
    @State private var newPartyName = ""
    @State private var addingParty = false

    /// Vorschläge aus der Personenliste: Personen mit bekannter Stimme zuerst.
    private var knownPeople: [KnownPerson] {
        voices.contacts
            .map { KnownPerson(name: $0.name, partyName: $0.partyName, hasVoice: voices.profile(named: $0.name) != nil) }
            .sorted { ($0.hasVoice ? 0 : 1, $0.name) < ($1.hasVoice ? 0 : 1, $1.name) }
    }

    private var recentSessions: [Session] {
        store.entries.map(\.session).filter { $0.people.count > 1 }.prefix(8).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Wer ist dabei?").sectionTitle()
                Spacer()
                Menu {
                    Button("Internes Meeting (eine Partei)") { draft.makeInternal() }
                    Button("Kunde + wir (Standard)") {
                        let title = draft.title
                        draft = .fromDefaults()
                        draft.title = title
                    }
                    if !recentSessions.isEmpty {
                        Section("Teilnehmer übernehmen von …") {
                            ForEach(recentSessions) { session in
                                Button("\(session.title) · \(session.startedAt.formatted(.dateTime.day().month(.abbreviated)))") {
                                    draft.copyParticipants(from: session)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Vorlage", systemImage: "rectangle.stack.badge.person.crop")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(draft.parties) { party in
                        PartySetupCard(draft: $draft, party: party, ownerName: ownerName, knownPeople: knownPeople)
                    }
                    if addingParty {
                        HStack {
                            TextField("Name der Partei, z. B. Partner GmbH", text: $newPartyName)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addParty)
                            Button("Hinzufügen", action: addParty)
                            Button("Abbrechen") { addingParty = false; newPartyName = "" }
                        }
                    } else {
                        Button {
                            addingParty = true
                        } label: {
                            Label("Weitere Partei", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .scrollIndicators(.automatic)

            Text("Die Ziffern sind deine Tastenkürzel im Gespräch (⌃⌥ + Zahl). Bekannte Stimmen (\(Image(systemName: "waveform"))) erkennt Cadence nach dem Gespräch automatisch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    private func addParty() {
        let name = newPartyName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        draft.addParty(named: name)
        newPartyName = ""
        addingParty = false
    }
}

struct KnownPerson: Hashable {
    let name: String
    let partyName: String?
    let hasVoice: Bool
}

private struct PartySetupCard: View {
    @Binding var draft: MeetingDraft
    let party: Party
    let ownerName: String
    let knownPeople: [KnownPerson]
    @State private var typed = ""
    @FocusState private var focused: Bool

    private var isOwnersParty: Bool { draft.ownerPartyID == party.id }

    private var suggestions: [KnownPerson] {
        let query = typed.trimmingCharacters(in: .whitespaces)
        let available = knownPeople.filter { !draft.contains(name: $0.name) && $0.name.caseInsensitiveCompare(ownerName) != .orderedSame }
        if query.isEmpty {
            // Ohne Eingabe: bekannte Personen dieser Partei anbieten.
            return Array(available.filter { $0.partyName?.caseInsensitiveCompare(party.name) == .orderedSame }.prefix(6))
        }
        return Array(available.filter { $0.name.localizedCaseInsensitiveContains(query) }.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(party.color.color).frame(width: 10, height: 10)
                TextField("Partei", text: Binding(
                    get: { party.name },
                    set: { draft.renameParty(party.id, to: $0) }
                ))
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .font(.callout.weight(.semibold))
                Spacer()
                if !isOwnersParty {
                    Button("Ich gehöre hierzu") { draft.ownerPartyID = party.id }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                if draft.parties.count > 1 {
                    Button {
                        draft.removeParty(party.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Partei entfernen")
                }
            }

            FlowLayout(spacing: 6) {
                if isOwnersParty {
                    NameChip(name: String(localized: "\(ownerName) (du)"), color: party.color.color, badge: "🎙")
                        .help("Du am Mikrofon – wirst immer automatisch erkannt")
                }
                ForEach(draft.people(in: party)) { person in
                    personChip(person)
                }
                HStack(spacing: 4) {
                    Image(systemName: "person.badge.plus").foregroundStyle(party.color.color)
                    TextField("Name + ⏎", text: $typed)
                        .textFieldStyle(.plain)
                        .focusEffectDisabled()
                        .frame(width: 110)
                        .focused($focused)
                        .onSubmit {
                            draft.addPerson(named: typed, partyID: party.id)
                            typed = ""
                            focused = true
                        }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.background, in: Capsule())
                .overlay(Capsule().strokeBorder(focused ? party.color.color : Color.secondary.opacity(0.25), lineWidth: 1))
            }

            if !suggestions.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(suggestions, id: \.self) { known in
                        Button {
                            draft.addPerson(named: known.name, partyID: party.id)
                            typed = ""
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: known.hasVoice ? "waveform" : "plus")
                                Text(known.name)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(known.hasVoice ? "Stimme bekannt – wird automatisch erkannt" : "Aus einem früheren Gespräch")
                    }
                }
            }
        }
        .padding(12)
        .background(party.color.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func personChip(_ person: Person) -> some View {
        let number = draft.hotkeyNumber(for: person)
        return HStack(spacing: 5) {
            if let number {
                Text("\(number)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(party.color.color, in: Circle())
            }
            Text(person.name).font(.callout.weight(.medium)).lineLimit(1)
            Button {
                draft.removePerson(person.id)
            } label: {
                Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(party.color.color.opacity(0.14), in: Capsule())
        .contextMenu {
            ForEach(draft.parties.filter { $0.id != party.id }) { other in
                Button("Zu „\(other.name)“ verschieben") { draft.movePerson(person.id, to: other.id) }
            }
        }
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
                row("⌃⌥ 1 … 9", String(localized: "Diese Person spricht gerade"))
                row("⌃⌥ 0", String(localized: "Sprecher unbekannt"))
                row("⌃⌥ N", String(localized: "Neuen Namen eintippen"))
                row("⌃⌥ M", String(localized: "Wichtige Stelle markieren"))
                row("⌃⌥ A", String(localized: "Aufgabe markieren"))
                row("⌃⌥ E", String(localized: "Entscheidung markieren"))
                row("⌃⌥ R", String(localized: "Aufnahme beenden"))
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
