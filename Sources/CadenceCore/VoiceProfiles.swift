import Foundation

/// Ein Stimm-Fingerabdruck aus einem bestimmten Gespräch.
public struct VoiceSample: Codable, Hashable, Sendable {
    public var sessionID: UUID
    public var embedding: [Float]
    public var date: Date

    public init(sessionID: UUID, embedding: [Float], date: Date = Date()) {
        self.sessionID = sessionID
        self.embedding = embedding
        self.date = date
    }
}

/// Gespeicherte Stimme einer Person, damit Cadence sie in künftigen Gesprächen wiedererkennt.
/// Alles bleibt lokal auf dem Mac.
public struct VoiceProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Name der Partei, in der die Person zuletzt war (z. B. „Kunde“, „Intern“).
    public var partyName: String?
    /// Je Gespräch ein Fingerabdruck, die neuesten zuletzt.
    public var samples: [VoiceSample]

    public init(id: UUID = UUID(), name: String, partyName: String?, samples: [VoiceSample]) {
        self.id = id
        self.name = name
        self.partyName = partyName
        self.samples = samples
    }

    public var embeddings: [[Float]] { samples.map(\.embedding) }
    public var sessionCount: Int { samples.count }
    public var updatedAt: Date { samples.map(\.date).max() ?? .distantPast }

    /// Höchstens so viele Fingerabdrücke je Person aufheben.
    public static let maxSamples = 12
}

/// Abgleich von Stimmen per Kosinus-Ähnlichkeit.
public enum VoiceMatcher {
    /// Ab dieser Ähnlichkeit gilt eine Stimme als erkannt. Bewusst vorsichtig gewählt:
    /// lieber „Sprecher 2“ stehen lassen als die falsche Person eintragen.
    public static let defaultThreshold: Float = 0.62
    /// Der beste Treffer muss so deutlich vor dem zweitbesten Profil liegen.
    public static let defaultMargin: Float = 0.06
    /// Cluster mit weniger Redezeit (Sekunden) liefern zu unsichere Fingerabdrücke.
    public static let minimumSpeechForProfile: Double = 6

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return -1 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// Ähnlichkeit einer Stimme zu einem Profil: bester Einzelvergleich.
    public static func similarity(_ embedding: [Float], to profile: VoiceProfile) -> Float {
        profile.embeddings.map { cosine(embedding, $0) }.max() ?? -1
    }

    /// Ordnet Cluster eindeutig Profilen zu (jedes Profil höchstens einmal pro Gespräch).
    public static func match(
        clusters: [Int: [Float]],
        profiles: [VoiceProfile],
        threshold: Float = defaultThreshold,
        margin: Float = defaultMargin
    ) -> [Int: UUID] {
        guard !profiles.isEmpty else { return [:] }
        var candidates: [(cluster: Int, profile: UUID, score: Float)] = []
        for (cluster, embedding) in clusters {
            let scores = profiles.map { (id: $0.id, score: similarity(embedding, to: $0)) }.sorted { $0.score > $1.score }
            guard let best = scores.first, best.score >= threshold else { continue }
            if scores.count > 1, best.score - scores[1].score < margin { continue }
            candidates.append((cluster, best.id, best.score))
        }
        var result: [Int: UUID] = [:]
        var usedProfiles = Set<UUID>()
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            guard result[candidate.cluster] == nil, !usedProfiles.contains(candidate.profile) else { continue }
            result[candidate.cluster] = candidate.profile
            usedProfiles.insert(candidate.profile)
        }
        return result
    }

    /// Nur endliche Werte – NaN würde das JSON zerstören.
    public static func sanitized(_ embedding: [Float]) -> [Float]? {
        guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else { return nil }
        return embedding
    }
}

public extension Session {
    /// Redezeit je Cluster (Sekunden).
    var speechPerCluster: [Int: Double] {
        var totals: [Int: Double] = [:]
        for segment in segments {
            guard let cluster = segment.clusterID else { continue }
            totals[cluster, default: 0] += segment.duration
        }
        return totals
    }

    /// Erkannte Stimmen eintragen: fehlende Personen (und Parteien) werden angelegt,
    /// vorhandene Zuordnungen bleiben unangetastet. Gibt die Namen der erkannten Personen zurück.
    @discardableResult
    mutating func applyRecognizedVoices(_ matches: [Int: UUID], profiles: [VoiceProfile]) -> [String] {
        var recognizedNames: [String] = []
        var recognized = recognizedClusters ?? [:]
        let alreadyAssigned = Set(clusterAssignments.values)
        for (cluster, profileID) in matches.sorted(by: { $0.key < $1.key }) {
            guard clusterAssignments[cluster] == nil,
                  let profile = profiles.first(where: { $0.id == profileID }) else { continue }
            let person: Person
            if let existing = people.first(where: { $0.name.caseInsensitiveCompare(profile.name) == .orderedSame }) {
                // Wer am eigenen Mikrofon sitzt, ist nicht im Systemaudio.
                guard !existing.isMicrophoneOwner, !alreadyAssigned.contains(existing.id) else { continue }
                person = existing
            } else {
                var partyID: UUID?
                if let partyName = profile.partyName, !partyName.isEmpty {
                    partyID = parties.first { $0.name.caseInsensitiveCompare(partyName) == .orderedSame }?.id
                        ?? addParty(named: partyName).id
                }
                person = addPerson(named: profile.name, partyID: partyID)
            }
            clusterAssignments[cluster] = person.id
            recognized[cluster] = profile.id
            recognizedNames.append(person.name)
        }
        recognizedClusters = recognized.isEmpty ? nil : recognized
        SpeakerResolver.resolve(&self)
        return recognizedNames
    }

    /// Stimmen, die diesem Gespräch eindeutig einer Person zugeordnet sind und genug Redezeit haben.
    /// Liefert (Name, Partei, Fingerabdruck) zum Lernen der Profile.
    func learnableVoices(minimumSpeech: Double = VoiceMatcher.minimumSpeechForProfile) -> [(name: String, partyName: String?, embedding: [Float])] {
        guard let embeddings = clusterEmbeddings else { return [] }
        let speech = speechPerCluster
        // Eine Person, die mehreren Clustern zugeordnet ist, nur mit ihrem längsten Cluster lernen.
        var bestCluster: [UUID: (cluster: Int, seconds: Double)] = [:]
        for (cluster, personID) in clusterAssignments {
            let seconds = speech[cluster] ?? 0
            guard seconds >= minimumSpeech, embeddings[cluster] != nil else { continue }
            if let current = bestCluster[personID], current.seconds >= seconds { continue }
            bestCluster[personID] = (cluster, seconds)
        }
        var result: [(name: String, partyName: String?, embedding: [Float])] = []
        for (personID, entry) in bestCluster {
            guard let person = person(personID), !person.isMicrophoneOwner,
                  let raw = embeddings[entry.cluster], let embedding = VoiceMatcher.sanitized(raw) else { continue }
            result.append((name: person.name, partyName: party(of: person)?.name, embedding: embedding))
        }
        return result.sorted { $0.name < $1.name }
    }
}

public extension Array where Element == VoiceProfile {
    /// Die Stimmen eines Gesprächs lernen. Frühere Beiträge desselben Gesprächs werden ersetzt,
    /// damit eine nachträglich korrigierte Zuordnung kein falsches Profil zurücklässt.
    mutating func learn(from session: Session, date: Date = Date()) {
        forget(sessionID: session.id)
        for voice in session.learnableVoices() {
            let sample = VoiceSample(sessionID: session.id, embedding: voice.embedding, date: date)
            if let index = firstIndex(where: { $0.name.caseInsensitiveCompare(voice.name) == .orderedSame }) {
                self[index].samples.append(sample)
                if self[index].samples.count > VoiceProfile.maxSamples {
                    self[index].samples.removeFirst(self[index].samples.count - VoiceProfile.maxSamples)
                }
                if let partyName = voice.partyName { self[index].partyName = partyName }
            } else {
                append(VoiceProfile(name: voice.name, partyName: voice.partyName, samples: [sample]))
            }
        }
    }

    /// Alle Beiträge eines Gesprächs entfernen; Profile ohne Fingerabdruck verschwinden.
    mutating func forget(sessionID: UUID) {
        for index in indices {
            self[index].samples.removeAll { $0.sessionID == sessionID }
        }
        removeAll { $0.samples.isEmpty }
    }
}
