import CadenceCore
import SwiftUI

/// Alle bekannten Personen: anzeigen, bearbeiten, zusammenführen, Stimme vergessen, löschen.
struct PeopleView: View {
    @EnvironmentObject private var voices: VoiceProfileStore
    @EnvironmentObject private var store: SessionStore
    @AppStorage(SettingsKey.voiceRecognition) private var voiceRecognition = true
    @State private var search = ""
    @State private var selection: UUID?
    @State private var showAdd = false

    private var filtered: [Contact] {
        voices.contacts
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || ($0.partyName ?? "").localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Nach Partei/Firma gruppiert, Personen ohne Angabe zuletzt.
    private var groups: [(title: String, people: [Contact])] {
        let grouped = Dictionary(grouping: filtered) { $0.partyName ?? "" }
        return grouped.keys.sorted { a, b in
            if a.isEmpty { return false }
            if b.isEmpty { return true }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        .map { (title: $0.isEmpty ? "Ohne Partei" : $0, people: grouped[$0] ?? []) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()
                if voices.contacts.isEmpty {
                    ContentUnavailableView("Noch keine Personen", systemImage: "person.2",
                                           description: Text("Personen aus deinen Gesprächen erscheinen hier automatisch. Du kannst sie auch vorab anlegen."))
                } else {
                    List(selection: $selection) {
                        ForEach(groups, id: \.title) { group in
                            Section(group.title) {
                                ForEach(group.people) { contact in
                                    PersonRow(contact: contact,
                                              hasVoice: voices.profile(named: contact.name) != nil,
                                              sessionCount: store.sessions(with: contact.name).count)
                                        .tag(contact.id)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 380)

            Divider()

            Group {
                if let id = selection, let contact = voices.contacts.first(where: { $0.id == id }) {
                    PersonDetail(contact: contact, onDeleted: { selection = nil })
                        .id(contact.id)
                } else {
                    VStack(spacing: 14) {
                        ContentUnavailableView("Person auswählen", systemImage: "person.crop.circle",
                                               description: Text("Name, Firma und Stimme bearbeiten oder Personen zusammenführen."))
                        Toggle("Stimmen merken und automatisch wiedererkennen", isOn: $voiceRecognition)
                            .toggleStyle(.switch)
                            .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showAdd) {
            AddPersonSheet { name, party in
                if let contact = voices.addContact(name: name, partyName: party) { selection = contact.id }
                showAdd = false
            } onCancel: { showAdd = false }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Personen suchen", text: $search)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
            Button {
                showAdd = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Person hinzufügen")
        }
        .padding(12)
    }
}

private struct PersonRow: View {
    let contact: Contact
    let hasVoice: Bool
    let sessionCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: contact.name, color: Theme.accent, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(contact.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(sessionCount == 1 ? "1 Gespräch" : "\(sessionCount) Gespräche")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hasVoice {
                Image(systemName: "waveform")
                    .foregroundStyle(Theme.accent)
                    .help("Stimme bekannt – wird automatisch erkannt")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PersonDetail: View {
    @EnvironmentObject private var voices: VoiceProfileStore
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var navigation: Navigation
    let contact: Contact
    let onDeleted: () -> Void

    @State private var name: String
    @State private var party: String
    @State private var note: String
    @State private var renameInSessions = true
    @State private var confirmDelete = false
    @State private var confirmForget = false

    init(contact: Contact, onDeleted: @escaping () -> Void) {
        self.contact = contact
        self.onDeleted = onDeleted
        _name = State(initialValue: contact.name)
        _party = State(initialValue: contact.partyName ?? "")
        _note = State(initialValue: contact.note ?? "")
    }

    private var profile: VoiceProfile? { voices.profile(named: contact.name) }
    private var sessions: [Session] { store.sessions(with: contact.name) }
    private var nameChanged: Bool { name.trimmingCharacters(in: .whitespaces) != contact.name }
    private var hasChanges: Bool { nameChanged || party != (contact.partyName ?? "") || note != (contact.note ?? "") }

    /// Bekannte Parteien/Firmen als Auswahl.
    private var knownParties: [String] {
        Array(Set(voices.contacts.compactMap(\.partyName) + store.entries.flatMap { $0.session.parties.map(\.name) }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Avatar(name: name.isEmpty ? contact.name : name, color: Theme.accent, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(contact.name).font(.system(.title2, design: .rounded).weight(.bold))
                        Text([contact.partyName, sessions.first.map { "zuletzt \($0.startedAt.formatted(date: .abbreviated, time: .omitted))" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Angaben").sectionTitle()
                    LabeledContent("Name") {
                        TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Partei / Firma") {
                        HStack {
                            TextField("z. B. Kunde, ACME GmbH, Intern", text: $party).textFieldStyle(.roundedBorder)
                            if !knownParties.isEmpty {
                                Menu {
                                    ForEach(knownParties, id: \.self) { option in
                                        Button(option) { party = option }
                                    }
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                            }
                        }
                    }
                    LabeledContent("Notiz") {
                        TextField("z. B. Rolle, Ansprechpartner für …", text: $note).textFieldStyle(.roundedBorder)
                    }
                    if nameChanged && !sessions.isEmpty {
                        Toggle("Auch in \(sessions.count == 1 ? "dem bisherigen Gespräch" : "den \(sessions.count) bisherigen Gesprächen") umbenennen", isOn: $renameInSessions)
                            .toggleStyle(.checkbox)
                    }
                    if let duplicate = duplicateTarget {
                        Text("„\(duplicate.name)“ gibt es schon. Beim Sichern werden beide zusammengeführt.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Spacer()
                        Button("Zurücksetzen") {
                            name = contact.name
                            party = contact.partyName ?? ""
                            note = contact.note ?? ""
                        }
                        .disabled(!hasChanges)
                        Button("Sichern", action: save)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut("s", modifiers: .command)
                            .disabled(!hasChanges || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .card()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Stimme").sectionTitle()
                    if let profile {
                        Label("Bekannt aus \(profile.sessionCount) \(profile.sessionCount == 1 ? "Gespräch" : "Gesprächen"), zuletzt aktualisiert am \(profile.updatedAt.formatted(date: .abbreviated, time: .omitted)).",
                              systemImage: "waveform")
                        Text("Cadence erkennt diese Stimme nach dem Gespräch automatisch. Wird sie verwechselt, vergiss sie hier. Bei der nächsten Zuordnung lernt Cadence sie neu.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Stimme vergessen …", role: .destructive) { confirmForget = true }
                    } else {
                        Text("Noch keine Stimme gespeichert. Sobald du dieser Person in einem Gespräch eine Stimme zuordnest, merkt sich Cadence sie.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Gespräche").sectionTitle()
                    if sessions.isEmpty {
                        Text("Noch in keinem Gespräch.").foregroundStyle(.secondary)
                    }
                    ForEach(sessions.prefix(12)) { session in
                        Button {
                            navigation.selection = .saved(session.id)
                        } label: {
                            HStack {
                                Text(session.title).lineLimit(1)
                                Spacer()
                                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Verwalten").sectionTitle()
                    let others = voices.contacts.filter { $0.id != contact.id }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    if !others.isEmpty {
                        Menu("Zusammenführen mit …") {
                            ForEach(others) { other in
                                Button(other.partyName.map { "\(other.name) · \($0)" } ?? other.name) {
                                    voices.merge(contact.id, into: other.id)
                                    store.renamePersonEverywhere(from: contact.name, to: other.name)
                                    onDeleted()
                                }
                            }
                        }
                        .fixedSize()
                        Text("Für doppelte Einträge, z. B. „Tom“ und „Thomas Müller“. Die Stimme und die Gespräche wandern zur ausgewählten Person.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Person löschen …", role: .destructive) { confirmDelete = true }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .confirmationDialog("\(contact.name) löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) {
                voices.deleteContact(contact.id)
                onDeleted()
            }
        } message: {
            Text("Die Person verschwindet aus den Vorschlägen, und ihre Stimme wird vergessen. Bisherige Gespräche bleiben unverändert.")
        }
        .confirmationDialog("Stimme von \(contact.name) vergessen?", isPresented: $confirmForget) {
            Button("Vergessen", role: .destructive) { voices.forgetVoice(of: contact.name) }
        }
    }

    private var duplicateTarget: Contact? {
        guard nameChanged else { return nil }
        return voices.contact(named: name.trimmingCharacters(in: .whitespaces)).flatMap { $0.id == contact.id ? nil : $0 }
    }

    private func save() {
        let newName = name.trimmingCharacters(in: .whitespaces)
        let oldName = contact.name
        let merging = duplicateTarget != nil
        voices.update(contact.id, name: newName, partyName: party, note: note)
        if newName != oldName && renameInSessions {
            store.renamePersonEverywhere(from: oldName, to: newName)
        }
        if merging { onDeleted() }
    }
}

private struct AddPersonSheet: View {
    let onAdd: (String, String?) -> Void
    let onCancel: () -> Void
    @State private var name = ""
    @State private var party = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Person hinzufügen").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Partei / Firma (optional)", text: $party).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Abbrechen", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Hinzufügen") { onAdd(name, party.nilIfBlank) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
