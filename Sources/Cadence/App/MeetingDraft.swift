import CadenceCore
import Foundation

/// Vorbereitung eines Gesprächs auf dem Startbildschirm: Titel, Parteien und Teilnehmer.
/// Liegt im `RecordingController`, damit nichts verloren geht, wenn man zwischendurch
/// ein altes Gespräch öffnet.
struct MeetingDraft: Equatable {
    var title = ""
    var parties: [Party]
    /// Vorab angelegte Teilnehmer – ohne dich.
    var people: [Person]
    /// Partei, zu der du gehörst.
    var ownerPartyID: UUID?

    static func fromDefaults() -> MeetingDraft {
        let defaults = UserDefaults.standard
        let own = Party(name: defaults.string(forKey: SettingsKey.ownPartyName) ?? "Wir", color: .blue)
        let other = Party(name: defaults.string(forKey: SettingsKey.otherPartyName) ?? "Kunde", color: .orange)
        return MeetingDraft(parties: [own, other], people: [], ownerPartyID: own.id)
    }

    /// So sähe das Gespräch aus – u. a. für die Ziffern 1–9 der Tastenkürzel.
    func makeSession(ownerName: String) -> Session {
        Session.new(
            title: title.trimmingCharacters(in: .whitespaces).isEmpty ? "Gespräch" : title,
            ownerName: ownerName,
            parties: parties,
            ownerPartyID: ownerPartyID,
            participants: people
        )
    }

    /// Ziffer (1–9) für das Tastenkürzel einer Person, falls vorhanden.
    func hotkeyNumber(for person: Person) -> Int? {
        guard let index = makeSession(ownerName: "\u{0}").hotkeyPeople.firstIndex(where: { $0.id == person.id }) else { return nil }
        return index + 1
    }

    func people(in party: Party) -> [Person] {
        people.filter { $0.partyID == party.id }
    }

    func contains(name: String) -> Bool {
        people.contains { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }

    mutating func addPerson(named raw: String, partyID: UUID?) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !contains(name: name) else { return }
        people.append(Person(name: name, partyID: partyID ?? parties.first?.id))
    }

    /// Person mit Parteiname (z. B. aus einem Stimmprofil) – legt die Partei bei Bedarf an.
    mutating func addPerson(named name: String, partyName: String?, fallbackPartyID: UUID?) {
        var partyID = fallbackPartyID
        if fallbackPartyID == nil, let partyName, !partyName.isEmpty {
            partyID = parties.first { $0.name.caseInsensitiveCompare(partyName) == .orderedSame }?.id ?? addParty(named: partyName).id
        }
        addPerson(named: name, partyID: partyID)
    }

    mutating func removePerson(_ id: UUID) {
        people.removeAll { $0.id == id }
    }

    mutating func movePerson(_ id: UUID, to partyID: UUID) {
        guard let index = people.firstIndex(where: { $0.id == id }) else { return }
        people[index].partyID = partyID
    }

    @discardableResult
    mutating func addParty(named name: String) -> Party {
        let used = Set(parties.map(\.color))
        let party = Party(name: name, color: PartyColor.allCases.first { !used.contains($0) } ?? .gray)
        parties.append(party)
        return party
    }

    mutating func renameParty(_ id: UUID, to name: String) {
        guard let index = parties.firstIndex(where: { $0.id == id }) else { return }
        parties[index].name = name
    }

    mutating func removeParty(_ id: UUID) {
        guard parties.count > 1 else { return }
        parties.removeAll { $0.id == id }
        let fallback = parties.first?.id
        for index in people.indices where people[index].partyID == id { people[index].partyID = fallback }
        if ownerPartyID == id { ownerPartyID = fallback }
    }

    /// Internes Meeting: eine einzige Partei, alle gehören dazu.
    mutating func makeInternal() {
        let party = Party(name: "Intern", color: .blue)
        parties = [party]
        ownerPartyID = party.id
        for index in people.indices { people[index].partyID = party.id }
    }

    /// Parteien und Teilnehmer aus einem früheren Gespräch übernehmen („wie letztes Mal“).
    mutating func copyParticipants(from session: Session) {
        parties = session.parties.isEmpty ? MeetingDraft.fromDefaults().parties : session.parties.map {
            Party(name: $0.name, color: $0.color)
        }
        // Parteien bekommen neue IDs; Personen entsprechend umhängen.
        let mapping = Dictionary(uniqueKeysWithValues: zip(session.parties.map(\.id), parties.map(\.id)))
        people = session.people.filter { !$0.isMicrophoneOwner }.map {
            Person(name: $0.name, partyID: $0.partyID.flatMap { mapping[$0] } ?? parties.first?.id)
        }
        ownerPartyID = session.microphoneOwner?.partyID.flatMap { mapping[$0] } ?? parties.first?.id
        if title.trimmingCharacters(in: .whitespaces).isEmpty { title = session.title }
    }
}
