import Foundation
import Testing
@testable import CadenceCore

struct SpeakerResolverTests {
    private func makeSession() -> (Session, Person, Person, Person) {
        var session = Session.new(title: "Test", ownerName: "Wayne")
        let owner = session.microphoneOwner!
        let anna = Person(name: "Anna", partyID: session.parties[1].id)
        let tom = Person(name: "Tom", partyID: session.parties[0].id)
        session.people += [anna, tom]
        return (session, owner, anna, tom)
    }

    @Test func testMicrophoneSegmentsBelongToOwner() {
        var (session, owner, _, _) = makeSession()
        session.segments = [TranscriptSegment(source: .microphone, start: 0, end: 2, text: "Hallo")]
        SpeakerResolver.resolve(&session)
        #expect(session.segments[0].personID == owner.id)
        #expect(session.segments[0].origin == .microphone)
    }

    @Test func testLiveTagsAssignSystemSegments() {
        var (session, _, anna, tom) = makeSession()
        session.speakerTags = [SpeakerTag(time: 1, personID: anna.id), SpeakerTag(time: 10, personID: tom.id)]
        session.segments = [
            TranscriptSegment(source: .system, start: 0, end: 0.8, text: "vorher"),
            TranscriptSegment(source: .system, start: 2, end: 5, text: "Anna"),
            TranscriptSegment(source: .system, start: 11, end: 13, text: "Tom")
        ]
        SpeakerResolver.resolve(&session)
        #expect(session.segments[0].personID == nil)
        #expect(session.segments[1].personID == anna.id)
        #expect(session.segments[2].personID == tom.id)
    }

    @Test func testClustersPropagateLiveTagsToWholeConversation() {
        var (session, _, anna, tom) = makeSession()
        // Nur ganz am Anfang live markiert …
        session.speakerTags = [SpeakerTag(time: 0, personID: anna.id), SpeakerTag(time: 5, personID: tom.id), SpeakerTag(time: 9, personID: nil)]
        session.segments = [
            TranscriptSegment(source: .system, start: 0, end: 4, text: "a1"),
            TranscriptSegment(source: .system, start: 5, end: 8, text: "t1"),
            TranscriptSegment(source: .system, start: 20, end: 24, text: "a2"),
            TranscriptSegment(source: .system, start: 30, end: 33, text: "t2")
        ]
        let turns = [
            DiarizedTurn(clusterID: 0, start: 0, end: 4.2),
            DiarizedTurn(clusterID: 1, start: 4.8, end: 8.1),
            DiarizedTurn(clusterID: 0, start: 19.5, end: 24),
            DiarizedTurn(clusterID: 1, start: 29.9, end: 33.5)
        ]
        SpeakerResolver.finalize(&session, turns: turns)
        // … und trotzdem ist der spätere Teil richtig zugeordnet.
        #expect(session.segments.map(\.personID) == [anna.id, tom.id, anna.id, tom.id])
        #expect(session.segments[2].origin == .cluster)
    }

    @Test func testOneLiveTagDoesNotNameTwoVoices() {
        var (session, _, anna, _) = makeSession()
        // Nur einmal am Anfang „Anna spricht“ gedrückt – danach antwortet jemand anderes.
        session.speakerTags = [SpeakerTag(time: 0, personID: anna.id)]
        session.segments = [
            TranscriptSegment(source: .system, start: 0, end: 10, text: "a1"),
            TranscriptSegment(source: .system, start: 10, end: 14, text: "b1"),
            TranscriptSegment(source: .system, start: 14, end: 24, text: "a2")
        ]
        let turns = [
            DiarizedTurn(clusterID: 0, start: 0, end: 10),
            DiarizedTurn(clusterID: 1, start: 10, end: 14),
            DiarizedTurn(clusterID: 0, start: 14, end: 24)
        ]
        SpeakerResolver.finalize(&session, turns: turns)
        #expect(session.clusterAssignments[0] == anna.id)
        #expect(session.clusterAssignments[1] == nil)
        #expect(session.segments.map(\.personID) == [anna.id, nil, anna.id])
        #expect(session.displayName(for: session.segments[1]) == "Sprecher 2")
    }

    @Test func testManualAssignmentWins() {
        var (session, _, anna, tom) = makeSession()
        session.speakerTags = [SpeakerTag(time: 0, personID: anna.id)]
        session.segments = [TranscriptSegment(source: .system, start: 1, end: 2, text: "x", manualPersonID: tom.id)]
        SpeakerResolver.resolve(&session)
        #expect(session.segments[0].personID == tom.id)
        #expect(session.segments[0].origin == .manual)
    }
}

struct SpeechChunkerTests {
    private func tone(_ seconds: Double, amplitude: Float = 0.2) -> [Float] {
        let n = Int(seconds * SpeechChunker.sampleRate)
        return (0..<n).map { amplitude * sin(Float($0) * 0.05) }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * SpeechChunker.sampleRate))
    }

    @Test func testCutsAtPauseAndKeepsTimeline() {
        var chunker = SpeechChunker(source: .system)
        var chunks: [SpeechChunk] = []
        chunks += chunker.append(silence(2))
        chunks += chunker.append(tone(2))
        chunks += chunker.append(silence(1))
        chunks += chunker.append(tone(1.5))
        if let last = chunker.flush() { chunks.append(last) }

        #expect(chunks.count == 2)
        #expect(abs(chunks[0].startTime - 1.7) <= 0.35)
        #expect(abs(chunks[1].startTime - 4.8) <= 0.6)
    }

    @Test func testDropsPureSilence() {
        var chunker = SpeechChunker(source: .microphone)
        #expect(chunker.append(silence(10)).isEmpty)
        #expect(chunker.flush() == nil)
    }

    @Test func testMaxDurationSplitsLongSpeech() {
        var chunker = SpeechChunker(source: .system)
        let chunks = chunker.append(tone(60))
        #expect(chunks.count >= 2)
        #expect(chunks.allSatisfy { $0.duration <= 25.1 })
    }
}

struct ExporterTests {
    @Test func testMarkdownGroupsTurnsAndShowsParties() throws {
        var session = Session.new(title: "Kickoff", ownerName: "Wayne")
        let anna = Person(name: "Anna", partyID: session.parties[1].id)
        session.people.append(anna)
        session.duration = 120
        session.startedAt = Date(timeIntervalSince1970: 1_764_072_000) // ganze Sekunden für den JSON-Roundtrip
        session.segments = [
            TranscriptSegment(source: .microphone, start: 0, end: 2, text: "Hallo zusammen."),
            TranscriptSegment(source: .microphone, start: 2.5, end: 4, text: "Legen wir los."),
            TranscriptSegment(source: .system, start: 5, end: 7, text: "Gerne.", manualPersonID: anna.id)
        ]
        session.markers = [Marker(time: 6, kind: .todo, text: "Angebot schicken")]
        SpeakerResolver.resolve(&session)

        let exporter = SessionExporter(session: session)
        let md = exporter.markdown()
        #expect(md.contains("**Wayne (Wir)** `0:00`\nHallo zusammen. Legen wir los."))
        #expect(md.contains("**Anna (Kunde)**"))
        #expect(md.contains("- **Kunde:** Anna"))

        let proto = exporter.protocolMarkdown()
        #expect(proto.contains("## Aufgaben\n\n- `0:06` ✅ Angebot schicken"))

        let json = try exporter.export(.json)
        let decoded = try SessionExporter.decoder.decode(Session.self, from: json)
        #expect(decoded == session)
    }

    @Test func testTimeFormats() {
        #expect(TimeFormat.clock(7) == "0:07")
        #expect(TimeFormat.clock(3723) == "1:02:03")
        #expect(TimeFormat.srt(62.345) == "00:01:02,345")
    }
}

struct CopyTextTests {
    private func session() -> Session {
        var session = Session.new(title: "Copy", ownerName: "Wayne")
        let anna = Person(name: "Anna", partyID: session.parties[1].id)
        session.people.append(anna)
        session.segments = [
            TranscriptSegment(source: .microphone, start: 0, end: 2, text: "Hallo."),
            TranscriptSegment(source: .system, start: 65, end: 67, text: "Hi!", manualPersonID: anna.id)
        ]
        SpeakerResolver.resolve(&session)
        return session
    }

    @Test func testAllFourVariants() {
        let exporter = SessionExporter(session: session())
        #expect(exporter.plainText(includeSpeakers: true, includeTimestamps: true) == "[0:00] Wayne: Hallo.\n\n[1:05] Anna: Hi!")
        #expect(exporter.plainText(includeSpeakers: true, includeTimestamps: false) == "Wayne: Hallo.\n\nAnna: Hi!")
        #expect(exporter.plainText(includeSpeakers: false, includeTimestamps: true) == "[0:00] Hallo.\n\n[1:05] Hi!")
        #expect(exporter.plainText(includeSpeakers: false, includeTimestamps: false) == "Hallo.\n\nHi!")
    }
}

struct SessionSetupTests {
    @Test func testParticipantsPreparedBeforeStart() {
        let parties = [Party(name: "Intern", color: .blue)]
        let tom = Person(name: " Tom ", partyID: parties[0].id)
        let duplicate = Person(name: "wayne", partyID: parties[0].id)
        let session = Session.new(title: "Weekly", ownerName: "Wayne", parties: parties, participants: [tom, duplicate])
        #expect(session.people.map(\.name) == ["Wayne", "Tom"])
        #expect(session.hotkeyPeople.map(\.name) == ["Tom"])
        #expect(session.people.allSatisfy { $0.partyID == parties[0].id })
    }

    @Test func testOldSessionJSONWithoutNewFieldsStillDecodes() throws {
        var session = Session.new(title: "Alt", ownerName: "Wayne")
        session.startedAt = Date(timeIntervalSince1970: 1_764_072_000)
        let data = try SessionExporter.encoder.encode(session)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "clusterEmbeddings")
        object.removeValue(forKey: "recognizedClusters")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try SessionExporter.decoder.decode(Session.self, from: stripped)
        #expect(decoded.clusterEmbeddings == nil)
        #expect(decoded.title == "Alt")
    }
}

struct VoiceProfileTests {
    private let annaVoice: [Float] = [0.9, 0.1, 0.0, 0.2]
    private let tomVoice: [Float] = [0.0, 0.8, 0.5, 0.1]

    /// Gespräch mit zwei Clustern, Anna und Tom zugeordnet.
    private func labeledSession() -> Session {
        var session = Session.new(title: "Erstes", ownerName: "Wayne")
        let anna = session.addPerson(named: "Anna", partyID: session.parties[1].id)
        let tom = session.addPerson(named: "Tom", partyID: session.parties[1].id)
        session.segments = [
            TranscriptSegment(source: .system, start: 0, end: 10, text: "a", clusterID: 0),
            TranscriptSegment(source: .system, start: 10, end: 20, text: "t", clusterID: 1),
            TranscriptSegment(source: .system, start: 20, end: 22, text: "kurz", clusterID: 2)
        ]
        session.clusterAssignments = [0: anna.id, 1: tom.id]
        session.clusterEmbeddings = [0: annaVoice, 1: tomVoice, 2: [0.3, 0.3, 0.3, 0.3]]
        return session
    }

    @Test func testLearnsAndRecognizesInNextMeeting() {
        var profiles: [VoiceProfile] = []
        profiles.learn(from: labeledSession())
        #expect(profiles.map(\.name).sorted() == ["Anna", "Tom"])
        #expect(profiles.first { $0.name == "Anna" }?.partyName == "Kunde")

        // Neues Gespräch: andere Cluster-Nummern, leicht veränderte Stimmen, Anna ist noch nicht angelegt.
        var next = Session.new(title: "Zweites", ownerName: "Wayne")
        next.segments = [
            TranscriptSegment(source: .system, start: 0, end: 5, text: "x", clusterID: 0),
            TranscriptSegment(source: .system, start: 5, end: 9, text: "y", clusterID: 1)
        ]
        next.clusterEmbeddings = [0: [0.02, 0.82, 0.48, 0.1], 1: [0.88, 0.12, 0.02, 0.21]]
        let matches = VoiceMatcher.match(clusters: next.clusterEmbeddings!, profiles: profiles)
        let names = next.applyRecognizedVoices(matches, profiles: profiles)
        #expect(names.sorted() == ["Anna", "Tom"])
        #expect(next.segments.map { next.person($0.personID)?.name } == ["Tom", "Anna"])
        #expect(next.person(next.segments[1].personID)?.partyID == next.parties.first { $0.name == "Kunde" }?.id)
    }

    @Test func testUnknownVoiceStaysUnassigned() {
        var profiles: [VoiceProfile] = []
        profiles.learn(from: labeledSession())
        let matches = VoiceMatcher.match(clusters: [0: [0.0, 0.0, -1.0, 0.9]], profiles: profiles)
        #expect(matches.isEmpty)
    }

    @Test func testCorrectionReplacesSameSessionSample() {
        var profiles: [VoiceProfile] = []
        var session = labeledSession()
        profiles.learn(from: session)
        // Nachträglich korrigiert: Cluster 0 war gar nicht Anna, sondern Bernd.
        let bernd = session.addPerson(named: "Bernd", partyID: session.parties[1].id)
        session.clusterAssignments[0] = bernd.id
        profiles.learn(from: session)
        #expect(profiles.map(\.name).sorted() == ["Bernd", "Tom"])
        #expect(profiles.allSatisfy { $0.sessionCount == 1 })
    }

    @Test func testManualAssignmentIsNotOverwrittenByRecognition() {
        var profiles: [VoiceProfile] = []
        profiles.learn(from: labeledSession())
        var next = Session.new(title: "Drittes", ownerName: "Wayne")
        let lisa = next.addPerson(named: "Lisa", partyID: nil)
        next.segments = [TranscriptSegment(source: .system, start: 0, end: 5, text: "x", clusterID: 0)]
        next.clusterAssignments = [0: lisa.id]
        let names = next.applyRecognizedVoices([0: profiles[0].id], profiles: profiles)
        #expect(names.isEmpty)
        #expect(next.clusterAssignments[0] == lisa.id)
    }
}

struct SummaryTests {
    @Test func testTranscriptChunksRespectLimitAndKeepTurns() {
        var session = Session.new(title: "Lang", ownerName: "Wayne")
        let text = String(repeating: "Wort ", count: 20)
        var segments: [TranscriptSegment] = []
        for i in 0..<40 {
            let source: AudioSource = i.isMultiple(of: 2) ? .microphone : .system
            let start = Double(i) * 10
            segments.append(TranscriptSegment(source: source, start: start, end: start + 5, text: text))
        }
        session.segments = segments
        SpeakerResolver.resolve(&session)
        let chunks = SessionExporter(session: session).transcriptChunks(maxCharacters: 400)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 400 })
        #expect(chunks.allSatisfy { $0.hasPrefix("[") })
    }

    @Test func testSummaryAppearsInProtocol() {
        var session = Session.new(title: "Kickoff", ownerName: "Wayne")
        session.summary = MeetingSummary(overview: "Projekt startet im Januar.", keyPoints: ["Budget steht"],
                                         decisions: ["Start am 15.1."], actionItems: [ActionItem(text: "Angebot schicken", owner: "Wayne")])
        let proto = SessionExporter(session: session).protocolMarkdown()
        #expect(proto.contains("## Zusammenfassung\n\nProjekt startet im Januar."))
        #expect(proto.contains("- [ ] Angebot schicken (Wayne)"))
        #expect(SessionExporter(session: session).summaryText()?.contains("• Start am 15.1.") == true)
    }
}

struct LiveSpeakerRegistryTests {
    @Test func testKeepsSpeakersStableAcrossWindows() {
        var registry = LiveSpeakerRegistry()
        let anna: [Float] = [1, 0, 0.1], tom: [Float] = [0, 1, 0.1]
        let first = registry.register([0: anna, 1: tom], speech: [0: 5, 1: 5])
        // Nächstes Fenster: lokale Nummern vertauscht, Stimmen leicht anders, dazu jemand Neues.
        let second = registry.register([0: [0.05, 0.95, 0.1], 1: [0.95, 0.05, 0.1], 2: [0, 0, 1]], speech: [0: 4, 1: 4, 2: 3])
        #expect(second[0] == first[1])
        #expect(second[1] == first[0])
        #expect(second[2] != first[0] && second[2] != first[1])
        #expect(registry.centroids.count == 3)
    }
}
