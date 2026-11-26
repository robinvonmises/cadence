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

public extension Session {
    /// Ersetzt das Live-Transkript durch eine sorgfältigere Fassung (nach dem Gespräch aus den
    /// Audiodateien). Von Hand zugeordnete Personen wandern mit: Ein neuer Abschnitt übernimmt die
    /// Person, deren manuell zugeordnete alte Abschnitte ihn zum größten Teil überdecken.
    mutating func replaceTranscript(with newSegments: [TranscriptSegment]) {
        let manual = segments.filter { $0.manualPersonID != nil }
        var result = newSegments.sorted { $0.start < $1.start }
        for index in result.indices {
            let segment = result[index]
            var overlapByPerson: [UUID: Double] = [:]
            for old in manual where old.source == segment.source {
                let overlap = min(segment.end, old.end) - max(segment.start, old.start)
                if overlap > 0, let person = old.manualPersonID { overlapByPerson[person, default: 0] += overlap }
            }
            if let best = overlapByPerson.max(by: { $0.value < $1.value }), best.value >= segment.duration * 0.5 {
                result[index].manualPersonID = best.key
            }
        }
        segments = result
        SpeakerResolver.resolve(&self)
    }
}

/// Fügt Whisper-Stücke zu ganzen Sätzen zusammen: Abschnittsgrenzen schneiden sonst mitten im Satz.
public enum SentenceMerger {
    /// Höchstens so lang wird ein zusammengefügtes Stück (Sekunden), damit Sprecherwechsel erkennbar bleiben.
    public static let maxDuration: Double = 30
    /// Größere Pausen beenden den Satz auch ohne Satzzeichen.
    public static let maxGap: Double = 1.2

    public static func merge(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for source in [AudioSource.microphone, .system] {
            var current: TranscriptSegment?
            for segment in segments.filter({ $0.source == source }).sorted(by: { $0.start < $1.start }) {
                if var open = current, canJoin(open, segment) {
                    open.text = open.text + " " + segment.text
                    open.end = max(open.end, segment.end)
                    current = open
                } else {
                    if let open = current { result.append(open) }
                    current = segment
                }
            }
            if let open = current { result.append(open) }
        }
        return result.sorted { $0.start < $1.start }
    }

    static func canJoin(_ a: TranscriptSegment, _ b: TranscriptSegment) -> Bool {
        guard a.manualPersonID == b.manualPersonID,
              b.start - a.end <= maxGap,
              max(a.end, b.end) - a.start <= maxDuration else { return false }
        return !endsSentence(a.text)
    }

    static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”„»«)]"))
        guard let last = trimmed.last else { return true }
        return ".!?…".contains(last)
    }
}
