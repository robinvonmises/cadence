import Foundation

/// Ein Abschnitt aus der automatischen Sprechertrennung (Diarization).
public struct DiarizedTurn: Codable, Hashable, Sendable {
    public var clusterID: Int
    public var start: Double
    public var end: Double

    public init(clusterID: Int, start: Double, end: Double) {
        self.clusterID = clusterID
        self.start = start
        self.end = end
    }
}

/// Führt die drei Informationsquellen für „wer spricht?“ zusammen:
///
/// 1. Mikrofon-Spur → immer der Mikrofon-Besitzer (du).
/// 2. Live-Hotkeys („ab jetzt spricht Anna“) für das Systemaudio.
/// 3. Diarization-Cluster nach Gesprächsende („Sprecher 2“). Ein Cluster bekommt automatisch
///    die Person, die ihm per Hotkey am häufigsten zugeordnet wurde – so reicht es, jede Person
///    ein- oder zweimal live zu markieren, und der Rest des Gesprächs wird korrekt zugeordnet.
///
/// Von Hand an einem Abschnitt gesetzte Personen gewinnen immer.
public enum SpeakerResolver {

    /// Person, die zum Zeitpunkt `time` laut Live-Tags spricht.
    public static func liveTaggedPerson(at time: Double, tags: [SpeakerTag]) -> UUID? {
        var current: UUID?
        for tag in tags.sorted(by: { $0.time < $1.time }) {
            if tag.time <= time { current = tag.personID } else { break }
        }
        return current
    }

    /// Ordnet jedem Systemaudio-Abschnitt den Cluster mit der größten zeitlichen Überlappung zu.
    public static func applyClusters(_ turns: [DiarizedTurn], to segments: inout [TranscriptSegment]) {
        guard !turns.isEmpty else { return }
        for index in segments.indices where segments[index].source == .system {
            let segment = segments[index]
            var overlapByCluster: [Int: Double] = [:]
            for turn in turns {
                let overlap = min(segment.end, turn.end) - max(segment.start, turn.start)
                if overlap > 0 { overlapByCluster[turn.clusterID, default: 0] += overlap }
            }
            if let best = overlapByCluster.max(by: { $0.value < $1.value }) {
                segments[index].clusterID = best.key
            } else if let nearest = turns.min(by: {
                distance($0, to: segment.midpoint) < distance($1, to: segment.midpoint)
            }), distance(nearest, to: segment.midpoint) < 1.5 {
                segments[index].clusterID = nearest.clusterID
            }
        }
    }

    private static func distance(_ turn: DiarizedTurn, to time: Double) -> Double {
        if time < turn.start { return turn.start - time }
        if time > turn.end { return time - turn.end }
        return 0
    }

    /// Leitet Cluster → Person aus Live-Tags und manuellen Zuordnungen ab (Mehrheitsentscheid,
    /// gewichtet nach Sprechdauer). Bereits vorhandene Zuordnungen bleiben erhalten.
    public static func inferClusterAssignments(
        segments: [TranscriptSegment],
        tags: [SpeakerTag],
        existing: [Int: UUID] = [:]
    ) -> [Int: UUID] {
        var votes: [Int: [UUID: Double]] = [:]
        for segment in segments where segment.source == .system {
            guard let cluster = segment.clusterID else { continue }
            let manual = segment.manualPersonID
            let live = liveTaggedPerson(at: segment.midpoint, tags: tags)
            // Manuelle Zuordnungen zählen deutlich stärker als Live-Tags.
            if let manual {
                votes[cluster, default: [:]][manual, default: 0] += max(segment.duration, 0.5) * 3
            } else if let live {
                votes[cluster, default: [:]][live, default: 0] += max(segment.duration, 0.5)
            }
        }

        var result = existing
        // Eine Person darf mehreren Clustern zugeordnet werden: Die Diarization teilt eine
        // Stimme gelegentlich in zwei Cluster auf, dann sollen beide dieselbe Person bekommen.
        for (cluster, personVotes) in votes where result[cluster] == nil {
            if let winner = personVotes.max(by: { $0.value < $1.value }) {
                result[cluster] = winner.key
            }
        }
        return result
    }

    /// Berechnet `personID` und `origin` aller Abschnitte neu.
    public static func resolve(_ session: inout Session) {
        let ownerID = session.microphoneOwner?.id
        let tags = session.speakerTags
        let clusters = session.clusterAssignments
        let knownPeople = Set(session.people.map(\.id))

        for index in session.segments.indices {
            var segment = session.segments[index]
            if let manual = segment.manualPersonID, knownPeople.contains(manual) {
                segment.personID = manual
                segment.origin = .manual
            } else if segment.source == .microphone {
                segment.personID = ownerID
                segment.origin = ownerID == nil ? .none : .microphone
            } else if let cluster = segment.clusterID, let person = clusters[cluster], knownPeople.contains(person) {
                segment.personID = person
                segment.origin = .cluster
            } else if let person = liveTaggedPerson(at: segment.midpoint, tags: tags), knownPeople.contains(person) {
                segment.personID = person
                segment.origin = .liveTag
            } else {
                segment.personID = nil
                segment.origin = .none
            }
            session.segments[index] = segment
        }
    }

    /// Kompletter Nachbearbeitungsschritt nach der Diarization.
    public static func finalize(_ session: inout Session, turns: [DiarizedTurn]) {
        applyClusters(turns, to: &session.segments)
        session.clusterAssignments = inferClusterAssignments(
            segments: session.segments,
            tags: session.speakerTags,
            existing: session.clusterAssignments
        )
        resolve(&session)
    }
}
