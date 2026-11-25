import CadenceCore
import Foundation

/// Eine bekannte Person – unabhängig von einem einzelnen Gespräch.
struct Contact: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// Partei bzw. Firma, z. B. „Kunde“, „ACME GmbH“, „Intern“.
    var partyName: String?
    var note: String?
}

/// Personen und ihre Stimmprofile, lokal in ~/Library/Application Support/Cadence/
/// (`personen.json` und `stimmen.json`). Lernt aus jedem gespeicherten Gespräch dazu.
@MainActor
final class VoiceProfileStore: ObservableObject {
    @Published private(set) var profiles: [VoiceProfile] = []
    @Published private(set) var contacts: [Contact] = []

    private struct PeopleFile: Codable {
        var contacts: [Contact]
        /// Gelöschte Personen (kleingeschrieben) → Zeitpunkt. Ältere Gespräche bringen sie nicht zurück.
        var removed: [String: Date]
    }

    private var removed: [String: Date] = [:]
    private let voicesURL: URL
    private let peopleURL: URL
    private var hasPeopleFile = false

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Cadence", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        voicesURL = folder.appendingPathComponent("stimmen.json")
        peopleURL = folder.appendingPathComponent("personen.json")
        load()
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.voiceRecognition) }

    func load() {
        if let data = try? Data(contentsOf: voicesURL),
           let decoded = try? SessionExporter.decoder.decode([VoiceProfile].self, from: data) {
            profiles = decoded
        }
        if let data = try? Data(contentsOf: peopleURL),
           let decoded = try? SessionExporter.decoder.decode(PeopleFile.self, from: data) {
            contacts = decoded.contacts
            removed = decoded.removed
            hasPeopleFile = true
        }
    }

    private func persistVoices() {
        guard let data = try? SessionExporter.encoder.encode(profiles) else { return }
        try? data.write(to: voicesURL, options: .atomic)
    }

    private func persistPeople() {
        guard let data = try? SessionExporter.encoder.encode(PeopleFile(contacts: contacts, removed: removed)) else { return }
        try? data.write(to: peopleURL, options: .atomic)
        hasPeopleFile = true
    }

    // MARK: - Abfragen

    func profile(named name: String) -> VoiceProfile? {
        profiles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func contact(named name: String) -> Contact? {
        contacts.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func isRemoved(_ name: String, before date: Date) -> Bool {
        guard let removedAt = removed[name.lowercased()] else { return false }
        return date <= removedAt
    }

    // MARK: - Aus Gesprächen lernen

    /// Beim allerersten Start: Personen aus allen bisherigen Gesprächen übernehmen.
    func seedIfNeeded(from sessions: [Session]) {
        guard !hasPeopleFile else { return }
        for profile in profiles where contact(named: profile.name) == nil {
            contacts.append(Contact(name: profile.name, partyName: profile.partyName))
        }
        for session in sessions.sorted(by: { $0.startedAt < $1.startedAt }) { addPeople(of: session) }
        persistPeople()
    }

    /// Wird bei jedem Speichern eines Gesprächs aufgerufen.
    func learn(from session: Session) {
        if addPeople(of: session) { persistPeople() }

        guard isEnabled, session.state == .finished, session.clusterEmbeddings != nil else { return }
        var updated = profiles
        updated.learn(from: session)
        // Gelöschte Personen nicht über ältere Gespräche wieder anlernen.
        for index in updated.indices where isRemoved(updated[index].name, before: session.startedAt) {
            updated[index].samples.removeAll { $0.sessionID == session.id }
        }
        updated.removeAll { $0.samples.isEmpty }
        guard updated != profiles else { return }
        profiles = updated
        persistVoices()
    }

    @discardableResult
    private func addPeople(of session: Session) -> Bool {
        var changed = false
        for person in session.people where !person.isMicrophoneOwner {
            let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !isRemoved(name, before: session.startedAt) else { continue }
            let partyName = session.party(of: person)?.name
            if let index = contacts.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                if contacts[index].partyName == nil, let partyName {
                    contacts[index].partyName = partyName
                    changed = true
                }
            } else {
                contacts.append(Contact(name: name, partyName: partyName))
                removed[name.lowercased()] = nil
                changed = true
            }
        }
        return changed
    }

    /// Bekannte Stimmen in einem frisch getrennten Gespräch eintragen.
    @discardableResult
    func recognize(in session: inout Session) -> [String] {
        guard isEnabled, let embeddings = session.clusterEmbeddings, !profiles.isEmpty else { return [] }
        // Parteien aus dem Adressbuch haben Vorrang vor der im Stimmprofil gemerkten.
        let current = profiles.map { profile -> VoiceProfile in
            var copy = profile
            if let party = contact(named: profile.name)?.partyName { copy.partyName = party }
            return copy
        }
        let open = embeddings.filter { session.clusterAssignments[$0.key] == nil }
        let matches = VoiceMatcher.match(clusters: open, profiles: current)
        return session.applyRecognizedVoices(matches, profiles: current)
    }

    // MARK: - Bearbeiten

    @discardableResult
    func addContact(name raw: String, partyName: String?) -> Contact? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let existing = contact(named: name) { return existing }
        let contact = Contact(name: name, partyName: partyName?.nilIfBlank)
        contacts.append(contact)
        removed[name.lowercased()] = nil
        persistPeople()
        return contact
    }

    /// Name, Partei/Firma und Notiz ändern. Ein neuer Name, den es schon gibt, führt beide zusammen.
    func update(_ id: UUID, name raw: String, partyName: String?, note: String?) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let oldName = contacts[index].name
        if name.caseInsensitiveCompare(oldName) != .orderedSame, let other = contact(named: name) {
            contacts[index].partyName = partyName?.nilIfBlank ?? contacts[index].partyName
            merge(id, into: other.id)
            return
        }
        contacts[index].name = name
        contacts[index].partyName = partyName?.nilIfBlank
        contacts[index].note = note?.nilIfBlank
        if let p = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(oldName) == .orderedSame }) {
            profiles[p].name = name
            profiles[p].partyName = partyName?.nilIfBlank
            persistVoices()
        }
        persistPeople()
    }

    /// Doppelte Person zusammenführen: Stimmproben wandern mit, die Quelle verschwindet.
    func merge(_ sourceID: UUID, into targetID: UUID) {
        guard sourceID != targetID,
              let source = contacts.first(where: { $0.id == sourceID }),
              let targetIndex = contacts.firstIndex(where: { $0.id == targetID }) else { return }
        let target = contacts[targetIndex]
        if contacts[targetIndex].partyName == nil { contacts[targetIndex].partyName = source.partyName }
        if contacts[targetIndex].note == nil { contacts[targetIndex].note = source.note }
        if let s = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(source.name) == .orderedSame }) {
            let samples = profiles[s].samples
            profiles.remove(at: s)
            if let t = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(target.name) == .orderedSame }) {
                profiles[t].samples = Array((profiles[t].samples + samples).sorted { $0.date < $1.date }.suffix(VoiceProfile.maxSamples))
            } else {
                profiles.append(VoiceProfile(name: target.name, partyName: contacts[targetIndex].partyName, samples: samples))
            }
            persistVoices()
        }
        contacts.removeAll { $0.id == sourceID }
        removed[source.name.lowercased()] = Date()
        persistPeople()
    }

    /// Person komplett entfernen – inklusive Stimmprofil. Alte Gespräche bleiben unverändert.
    func deleteContact(_ id: UUID) {
        guard let contact = contacts.first(where: { $0.id == id }) else { return }
        contacts.removeAll { $0.id == id }
        removed[contact.name.lowercased()] = Date()
        forgetVoice(of: contact.name)
        persistPeople()
    }

    /// Nur die Stimme vergessen; sie wird bei der nächsten Zuordnung neu angelernt.
    func forgetVoice(of name: String) {
        let before = profiles.count
        profiles.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if profiles.count != before { persistVoices() }
    }

    func delete(_ profileID: UUID) {
        profiles.removeAll { $0.id == profileID }
        persistVoices()
    }

    func deleteAll() {
        profiles = []
        persistVoices()
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
