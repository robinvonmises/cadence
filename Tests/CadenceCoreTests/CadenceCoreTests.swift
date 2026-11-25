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
