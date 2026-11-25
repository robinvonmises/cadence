import Foundation

// MARK: - Parteien & Personen

/// Eine Gesprächspartei, z. B. „Wir“ (eigene Firma), „Kunde“ oder ein weiterer Partner.
public struct Party: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Farbname aus `PartyColor`, damit das Modell frei von UI-Frameworks bleibt.
    public var color: PartyColor

    public init(id: UUID = UUID(), name: String, color: PartyColor) {
        self.id = id
        self.name = name
        self.color = color
    }
}

public enum PartyColor: String, Codable, CaseIterable, Sendable {
    case blue, orange, green, purple, pink, teal, gray
}

/// Eine Person im Gespräch. Die Person am eigenen Mikrofon ist mit `isMicrophoneOwner` markiert.
public struct Person: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var partyID: UUID?
    public var isMicrophoneOwner: Bool

    public init(id: UUID = UUID(), name: String, partyID: UUID?, isMicrophoneOwner: Bool = false) {
        self.id = id
        self.name = name
        self.partyID = partyID
        self.isMicrophoneOwner = isMicrophoneOwner
    }
}

// MARK: - Transkript

/// Woher das Audio eines Abschnitts stammt.
public enum AudioSource: String, Codable, Sendable {
    /// Eigenes Mikrofon – das bist (fast immer) du selbst.
    case microphone
    /// Systemaudio – die anderen Teilnehmer aus Teams, Zoom, Meet, …
    case system
}

/// Wie die Person eines Abschnitts zustande kam (wichtig für die Rangfolge beim Neuberechnen).
public enum AssignmentOrigin: String, Codable, Sendable {
    /// Von Hand am Abschnitt gesetzt – gewinnt immer.
    case manual
    /// Über die Zuordnung eines Diarization-Clusters („Sprecher 2“ → Anna).
    case cluster
    /// Über den Live-Hotkey während des Gesprächs.
    case liveTag
    /// Mikrofon-Spur → Mikrofon-Besitzer.
    case microphone
    case none
}

public struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var source: AudioSource
    /// Sekunden seit Aufnahmebeginn.
    public var start: Double
    public var end: Double
    public var text: String
    /// Cluster-ID aus der Sprechertrennung (nur Systemaudio).
    public var clusterID: Int?
    /// Aufgelöste Person.
    public var personID: UUID?
    public var origin: AssignmentOrigin
    /// Von Hand gesetzte Person (überschreibt alles andere).
    public var manualPersonID: UUID?

    public init(
        id: UUID = UUID(),
        source: AudioSource,
        start: Double,
        end: Double,
        text: String,
        clusterID: Int? = nil,
        personID: UUID? = nil,
        origin: AssignmentOrigin = .none,
        manualPersonID: UUID? = nil
    ) {
        self.id = id
        self.source = source
        self.start = start
        self.end = end
        self.text = text
        self.clusterID = clusterID
        self.personID = personID
        self.origin = origin
        self.manualPersonID = manualPersonID
    }

    public var midpoint: Double { (start + end) / 2 }
    public var duration: Double { max(0, end - start) }
}

/// „Ab jetzt spricht X“ – per Hotkey oder Klick während des Gesprächs gesetzt.
public struct SpeakerTag: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var time: Double
    /// `nil` bedeutet „unbekannt / niemand Bestimmtes“.
    public var personID: UUID?

    public init(id: UUID = UUID(), time: Double, personID: UUID?) {
        self.id = id
        self.time = time
        self.personID = personID
    }
}

public enum MarkerKind: String, Codable, CaseIterable, Sendable {
    case note        // freie Notiz
    case highlight   // wichtige Stelle
    case todo        // Aufgabe / Action Item
    case decision    // Entscheidung
    case consent     // Einwilligung dokumentiert

    public var label: String {
        switch self {
        case .note: return "Notiz"
        case .highlight: return "Wichtig"
        case .todo: return "Aufgabe"
        case .decision: return "Entscheidung"
        case .consent: return "Einwilligung"
        }
    }

    public var emoji: String {
        switch self {
        case .note: return "📝"
        case .highlight: return "⭐️"
        case .todo: return "✅"
        case .decision: return "⚖️"
        case .consent: return "🛡️"
        }
    }
}

public struct Marker: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var time: Double
    public var kind: MarkerKind
    public var text: String

    public init(id: UUID = UUID(), time: Double, kind: MarkerKind, text: String) {
        self.id = id
        self.time = time
        self.kind = kind
        self.text = text
    }
}

// MARK: - Session

public struct AudioFiles: Codable, Hashable, Sendable {
    /// Dateinamen relativ zum Session-Ordner.
    public var system: String?
    public var microphone: String?
    public var combined: String?

    public init(system: String? = nil, microphone: String? = nil, combined: String? = nil) {
        self.system = system
        self.microphone = microphone
        self.combined = combined
    }
}

public enum SessionState: String, Codable, Sendable {
    case recording
    case processing
    case finished
}

/// Ein aufgezeichnetes Gespräch mit allem, was dazugehört.
public struct Session: Identifiable, Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var duration: Double
    public var state: SessionState
    public var sourceDescription: String
    public var language: String?
    public var parties: [Party]
    public var people: [Person]
    public var segments: [TranscriptSegment]
    public var speakerTags: [SpeakerTag]
    public var markers: [Marker]
    /// Diarization-Cluster → Person, von Hand oder automatisch abgeleitet.
    public var clusterAssignments: [Int: UUID]
    public var audio: AudioFiles
    public var consentConfirmed: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date = Date(),
        duration: Double = 0,
        state: SessionState = .recording,
        sourceDescription: String = "",
        language: String? = nil,
        parties: [Party] = Session.defaultParties,
        people: [Person] = [],
        segments: [TranscriptSegment] = [],
        speakerTags: [SpeakerTag] = [],
        markers: [Marker] = [],
        clusterAssignments: [Int: UUID] = [:],
        audio: AudioFiles = AudioFiles(),
        consentConfirmed: Bool = false
    ) {
        self.schemaVersion = Session.currentSchemaVersion
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.state = state
        self.sourceDescription = sourceDescription
        self.language = language
        self.parties = parties
        self.people = people
        self.segments = segments
        self.speakerTags = speakerTags
        self.markers = markers
        self.clusterAssignments = clusterAssignments
        self.audio = audio
        self.consentConfirmed = consentConfirmed
    }

    public static var defaultParties: [Party] {
        [
            Party(name: "Wir", color: .blue),
            Party(name: "Kunde", color: .orange)
        ]
    }

    /// Neue Session mit dem Mikrofon-Besitzer in der ersten Partei.
    public static func new(title: String, ownerName: String, parties: [Party] = Session.defaultParties) -> Session {
        var session = Session(title: title, parties: parties)
        let owner = Person(name: ownerName, partyID: parties.first?.id, isMicrophoneOwner: true)
        session.people = [owner]
        return session
    }

    // MARK: Abfragen

    public var microphoneOwner: Person? { people.first { $0.isMicrophoneOwner } }

    public func person(_ id: UUID?) -> Person? {
        guard let id else { return nil }
        return people.first { $0.id == id }
    }

    public func party(_ id: UUID?) -> Party? {
        guard let id else { return nil }
        return parties.first { $0.id == id }
    }

    public func party(of person: Person?) -> Party? { party(person?.partyID) }

    public func people(in party: Party) -> [Person] {
        people.filter { $0.partyID == party.id }
    }

    public var peopleWithoutParty: [Person] {
        people.filter { p in p.partyID == nil || !parties.contains { $0.id == p.partyID } }
    }

    public var sortedSegments: [TranscriptSegment] {
        segments.sorted { $0.start < $1.start }
    }

    /// Anzeigename für einen Abschnitt, mit sinnvollen Rückfallebenen.
    public func displayName(for segment: TranscriptSegment) -> String {
        if let person = person(segment.personID) { return person.name }
        if let cluster = segment.clusterID { return "Sprecher \(cluster + 1)" }
        switch segment.source {
        case .microphone: return microphoneOwner?.name ?? "Ich"
        case .system: return "Unbekannt"
        }
    }

    /// Alle Cluster-IDs, die im Transkript vorkommen.
    public var clusterIDs: [Int] {
        Array(Set(segments.compactMap(\.clusterID))).sorted()
    }

    /// Redeanteile je Person (Sekunden), absteigend sortiert.
    public func speakingTime() -> [(name: String, seconds: Double)] {
        var totals: [String: Double] = [:]
        for segment in segments {
            totals[displayName(for: segment), default: 0] += segment.duration
        }
        return totals.map { (name: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds }
    }
}
