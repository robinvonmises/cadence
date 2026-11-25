import Foundation

/// Bearbeitungsfunktionen, die sowohl live als auch nachträglich verwendet werden.
public extension Session {
    /// Person hinzufügen oder – bei gleichem Namen – die vorhandene zurückgeben.
    @discardableResult
    mutating func addPerson(named rawName: String, partyID: UUID?) -> Person {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = people.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let person = Person(name: name, partyID: partyID)
        people.append(person)
        return person
    }

    mutating func renamePerson(_ id: UUID, to name: String) {
        guard let index = people.firstIndex(where: { $0.id == id }) else { return }
        people[index].name = name
    }

    mutating func movePerson(_ id: UUID, toParty partyID: UUID?) {
        guard let index = people.firstIndex(where: { $0.id == id }) else { return }
        people[index].partyID = partyID
    }

    /// Person entfernen; ihre Zuordnungen werden aufgelöst.
    mutating func removePerson(_ id: UUID) {
        guard let person = person(id), !person.isMicrophoneOwner else { return }
        people.removeAll { $0.id == id }
        for index in segments.indices where segments[index].manualPersonID == id {
            segments[index].manualPersonID = nil
        }
        speakerTags = speakerTags.map { $0.personID == id ? SpeakerTag(id: $0.id, time: $0.time, personID: nil) : $0 }
        clusterAssignments = clusterAssignments.filter { $0.value != id }
        SpeakerResolver.resolve(&self)
    }

    @discardableResult
    mutating func addParty(named name: String) -> Party {
        let used = Set(parties.map(\.color))
        let color = PartyColor.allCases.first { !used.contains($0) } ?? .gray
        let party = Party(name: name, color: color)
        parties.append(party)
        return party
    }

    mutating func renameParty(_ id: UUID, to name: String) {
        guard let index = parties.firstIndex(where: { $0.id == id }) else { return }
        parties[index].name = name
    }

    mutating func removeParty(_ id: UUID) {
        parties.removeAll { $0.id == id }
        for index in people.indices where people[index].partyID == id {
            people[index].partyID = nil
        }
    }

    /// Einen einzelnen Abschnitt von Hand zuordnen (`nil` = Zuordnung zurücksetzen).
    mutating func assign(segment segmentID: UUID, to personID: UUID?) {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        segments[index].manualPersonID = personID
        SpeakerResolver.resolve(&self)
    }

    /// Mehrere Abschnitte (z. B. einen ganzen Wortbeitrag) auf einmal zuordnen.
    mutating func assign(segments segmentIDs: [UUID], to personID: UUID?) {
        let ids = Set(segmentIDs)
        for index in segments.indices where ids.contains(segments[index].id) {
            segments[index].manualPersonID = personID
        }
        SpeakerResolver.resolve(&self)
    }

    /// Alle Abschnitte eines Diarization-Clusters einer Person zuordnen.
    mutating func assign(cluster: Int, to personID: UUID?) {
        clusterAssignments[cluster] = personID
        SpeakerResolver.resolve(&self)
    }

    /// „Ab hier spricht …“ nachträglich setzen.
    mutating func tagSpeaker(_ personID: UUID?, at time: Double) {
        speakerTags.append(SpeakerTag(time: time, personID: personID))
        speakerTags.sort { $0.time < $1.time }
        SpeakerResolver.resolve(&self)
    }

    mutating func updateText(segment segmentID: UUID, text: String) {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        segments[index].text = text
    }

    mutating func deleteSegment(_ segmentID: UUID) {
        segments.removeAll { $0.id == segmentID }
    }

    @discardableResult
    mutating func addMarker(_ kind: MarkerKind, text: String, at time: Double) -> Marker {
        let marker = Marker(time: time, kind: kind, text: text.isEmpty ? kind.label : text)
        markers.append(marker)
        markers.sort { $0.time < $1.time }
        return marker
    }

    mutating func removeMarker(_ id: UUID) {
        markers.removeAll { $0.id == id }
    }

    /// Teilnehmer, die per Hotkey 1…9 erreichbar sind (alle außer dir, in Partei-Reihenfolge).
    var hotkeyPeople: [Person] {
        let order = Dictionary(uniqueKeysWithValues: parties.enumerated().map { ($0.element.id, $0.offset) })
        return people
            .filter { !$0.isMicrophoneOwner }
            .enumerated()
            .sorted {
                let a = order[$0.element.partyID ?? UUID()] ?? Int.max
                let b = order[$1.element.partyID ?? UUID()] ?? Int.max
                return a == b ? $0.offset < $1.offset : a < b
            }
            .map(\.element)
            .prefix(9)
            .map { $0 }
    }
}
