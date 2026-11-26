import AVFoundation
import CadenceCore
import Combine
import Foundation

/// Steuert eine laufende Aufnahme: Audio → Abschnitte → Transkription → Sprecherzuordnung → Speichern.
@MainActor
final class RecordingController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case recording
        case finishing(String)
    }

    @Published var session: Session?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    /// Nachbearbeitung eines gespeicherten Gesprächs (z. B. nachträglich transkribieren).
    @Published private(set) var reprocessing: (id: UUID, status: String)?
    @Published private(set) var backlog: Int = 0
    @Published private(set) var currentSpeakerID: UUID?
    @Published var errorMessage: String?
    /// Namen, die nach dem letzten Gespräch per Stimmprofil erkannt wurden (für einen Hinweis).
    @Published var lastRecognizedNames: [String] = []
    /// Vorbereitung des nächsten Gesprächs (Startbildschirm).
    @Published var draft = MeetingDraft.fromDefaults()
    /// Wird gesetzt, wenn per Hotkey das Namensfeld fokussiert werden soll.
    @Published var focusSpeakerFieldRequest = UUID()

    private let store: SessionStore
    let models: ModelManager
    private let diarizer = DiarizationEngine()
    private let systemTap = SystemAudioTap()
    private let microphone = MicrophoneCapture()
    private var systemTrack: AudioTrackRecorder?
    private var micTrack: AudioTrackRecorder?
    private var chunkContinuation: AsyncStream<SpeechChunk>.Continuation?
    private var transcriptionTask: Task<Void, Never>?
    private var clockTimer: Timer?
    private var autosaveTimer: Timer?
    private var watchdogTimer: Timer?
    private var systemTarget: SystemAudioTarget = .allSystemAudio
    private var lastMicSound = Date()
    private var systemRestarts = 0
    /// Hinweis während der Aufnahme, wenn eine Spur nichts liefert.
    @Published private(set) var audioWarning: String?
    private var startDate = Date()
    private var liveTranscriptionWorked = true

    // Live-Stimmerkennung
    private var liveDiarizationContinuation: AsyncStream<SpeechChunk>.Continuation?
    private var liveDiarizationTask: Task<Void, Never>?
    private var liveRegistry = LiveSpeakerRegistry()
    private var liveTurns: [DiarizedTurn] = []
    /// Stimmen, die du live per Klick einer Person zugeordnet hast (Cluster → Person).
    private var pinnedClusters: [Int: UUID] = [:]
    /// Ist die Live-Stimmerkennung in dieser Aufnahme aktiv?
    @Published private(set) var liveDiarizationActive = false

    init(store: SessionStore, models: ModelManager) {
        self.store = store
        self.models = models
    }

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { phase != .idle }

    // MARK: - Start

    func start(draft: MeetingDraft, target: SystemAudioTarget, consentConfirmed: Bool) async {
        guard phase == .idle else { return }
        phase = .preparing
        errorMessage = nil
        lastRecognizedNames = []

        let defaults = UserDefaults.standard
        let recordMicrophone = defaults.bool(forKey: SettingsKey.recordMicrophone)
        if recordMicrophone, !(await MicrophoneCapture.requestPermission()) {
            fail(String(localized: "Kein Zugriff auf das Mikrofon. Bitte in Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon erlauben."))
            return
        }

        var newSession = draft.makeSession(ownerName: defaults.string(forKey: SettingsKey.ownerName) ?? Defaults.ownerName)
        newSession.sourceDescription = target.label
        let language = LanguageOption(rawValue: defaults.string(forKey: SettingsKey.language) ?? "de") ?? .german
        newSession.language = language.whisperCode
        newSession.consentConfirmed = consentConfirmed
        newSession.audio = AudioFiles(system: "system.m4a", microphone: recordMicrophone ? "mikrofon.m4a" : nil)
        if consentConfirmed {
            newSession.addMarker(.consent, text: String(localized: "Einwilligung zur Aufzeichnung bestätigt"), at: 0)
        }

        newSession.startedAt = Date()
        let folder: URL
        do {
            folder = try store.save(newSession, writeMarkdown: false)
        } catch {
            fail(String(localized: "Speicherort nicht beschreibbar: \(error.localizedDescription)"))
            return
        }
        do {
            systemTrack = try AudioTrackRecorder(source: .system, fileURL: folder.appendingPathComponent("system.m4a"))
            micTrack = recordMicrophone
                ? try AudioTrackRecorder(source: .microphone, fileURL: folder.appendingPathComponent("mikrofon.m4a"))
                : nil
        } catch {
            store.delete(newSession.id)
            fail(String(localized: "Audiodateien konnten nicht angelegt werden: \(error.localizedDescription)"))
            return
        }

        // Abschnitte beider Spuren landen in einer gemeinsamen Warteschlange.
        let (stream, continuation) = AsyncStream<SpeechChunk>.makeStream()
        chunkContinuation = continuation
        let liveDiarization = defaults.bool(forKey: SettingsKey.liveDiarization) && defaults.bool(forKey: SettingsKey.runDiarization)
        var liveStream: AsyncStream<SpeechChunk>?
        if liveDiarization {
            let (stream, liveContinuation) = AsyncStream<SpeechChunk>.makeStream()
            liveStream = stream
            liveDiarizationContinuation = liveContinuation
        }
        let liveContinuation = liveDiarizationContinuation
        for track in [systemTrack, micTrack].compactMap({ $0 }) {
            let source = track.source
            track.onChunk = { chunk in
                continuation.yield(chunk)
                if source == .system { liveContinuation?.yield(chunk) }
            }
            track.onLevel = { [weak self] level in
                Task { @MainActor in
                    guard let self else { return }
                    if source == .system { self.systemLevel = level } else {
                        self.micLevel = level
                        if level > 0.0001 { self.lastMicSound = Date() }
                    }
                }
            }
        }

        systemTarget = target
        systemRestarts = 0
        audioWarning = nil
        do {
            try startSystemTap()
        } catch {
            store.delete(newSession.id)
            fail(String(localized: "Systemaudio konnte nicht aufgenommen werden: \(error.localizedDescription)\n\nPrüfe Systemeinstellungen → Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme."))
            return
        }
        if let micRecorder = micTrack {
            do {
                let voiceProcessing = defaults.bool(forKey: SettingsKey.voiceProcessing)
                let deviceUID = defaults.string(forKey: SettingsKey.microphoneDevice).flatMap { $0.isEmpty ? nil : $0 }
                try microphone.start(voiceProcessing: voiceProcessing, deviceUID: deviceUID) { buffer in micRecorder.append(buffer) }
            } catch {
                systemTap.stop()
                store.delete(newSession.id)
                fail(String(localized: "Mikrofon konnte nicht gestartet werden: \(error.localizedDescription)"))
                return
            }
        }

        startDate = Date()
        session = newSession
        self.draft = .fromDefaults()
        currentSpeakerID = nil
        elapsed = 0
        phase = .recording
        startTimers()

        liveTranscriptionWorked = true
        transcriptionTask = Task { [weak self] in
            await self?.runTranscription(stream: stream, language: language.whisperCode)
        }
        liveRegistry = LiveSpeakerRegistry()
        liveTurns = []
        pinnedClusters = [:]
        liveDiarizationActive = liveStream != nil
        if let liveStream {
            liveDiarizationTask = Task { [weak self] in
                await self?.runLiveDiarization(stream: liveStream)
            }
        }
    }

    private func runTranscription(stream: AsyncStream<SpeechChunk>, language: String?) async {
        // Abschnitte warten im Stream, bis das Modell bereit ist (z. B. beim ersten Download).
        guard await models.ensureReady() else {
            // Audio wird trotzdem aufgenommen; transkribiert wird nach dem Stoppen aus den Dateien.
            liveTranscriptionWorked = false
            for await _ in stream {}
            return
        }
        for await chunk in stream {
            backlog += 1
            let segments = await models.engine.transcribe(chunk, language: language)
            backlog -= 1
            add(segments)
        }
    }

    private func add(_ segments: [TranscriptSegment]) {
        guard !segments.isEmpty, var current = session else { return }
        current.segments.append(contentsOf: segments)
        current.segments.sort { $0.start < $1.start }
        if !liveTurns.isEmpty { SpeakerResolver.applyClusters(liveTurns, to: &current.segments) }
        SpeakerResolver.resolve(&current)
        session = current
    }

    // MARK: - Live-Stimmerkennung

    /// Sammelt Sprache der Gegenseite und trennt sie alle ~20 Sekunden in Stimmen.
    /// Die Fenster werden über Stimm-Fingerabdrücke zu dauerhaften Sprechern verbunden.
    private func runLiveDiarization(stream: AsyncStream<SpeechChunk>) async {
        var buffer: [SpeechChunk] = []
        var bufferedSeconds = 0.0
        for await chunk in stream {
            buffer.append(chunk)
            bufferedSeconds += chunk.duration
            guard bufferedSeconds >= 20 else { continue }
            await diarizeLiveWindow(buffer)
            // Etwas Überlappung behalten, damit Sprecherwechsel an der Grenze nicht verloren gehen.
            if let last = buffer.last, last.duration < 8 {
                buffer = [last]
                bufferedSeconds = last.duration
            } else {
                buffer = []
                bufferedSeconds = 0
            }
        }
        // Nach dem Stoppen übernimmt die vollständige Sprechertrennung den Rest.
    }

    private func diarizeLiveWindow(_ chunks: [SpeechChunk]) async {
        // Abschnitte aneinanderhängen und merken, wo jeder im Gesprächsverlauf lag.
        var samples: [Float] = []
        var offsets: [(local: Double, absolute: Double, duration: Double)] = []
        for chunk in chunks {
            offsets.append((Double(samples.count) / SpeechChunker.sampleRate, chunk.startTime, chunk.duration))
            samples += chunk.samples
        }
        guard let output = try? await diarizer.diarize(samples: samples, expectedSpeakers: nil),
              !output.turns.isEmpty else { return }

        var speech: [Int: Double] = [:]
        for turn in output.turns { speech[turn.clusterID, default: 0] += turn.end - turn.start }
        let mapping = liveRegistry.register(output.embeddings, speech: speech)

        // Lokale Zeiten zurück auf die Gesprächszeit abbilden (an Abschnittsgrenzen teilen).
        var turns: [DiarizedTurn] = []
        for turn in output.turns {
            guard let global = mapping[turn.clusterID] else { continue }
            for piece in offsets {
                let start = max(turn.start, piece.local), end = min(turn.end, piece.local + piece.duration)
                guard end > start else { continue }
                turns.append(DiarizedTurn(clusterID: global,
                                          start: piece.absolute + (start - piece.local),
                                          end: piece.absolute + (end - piece.local)))
            }
        }
        // Neuere Fenster ersetzen ältere im überlappenden Bereich.
        if let first = turns.map(\.start).min(), let last = turns.map(\.end).max() {
            liveTurns.removeAll { $0.start >= first && $0.end <= last }
        }
        liveTurns += turns
        liveTurns.sort { $0.start < $1.start }
        applyLiveClusters()
    }

    /// Cluster auf das Transkript anwenden und – wo möglich – Personen zuordnen:
    /// deine Klicks zuerst, dann deine Live-Markierungen, dann bekannte Stimmen.
    private func applyLiveClusters() {
        guard var current = session, !liveTurns.isEmpty else { return }
        SpeakerResolver.applyClusters(liveTurns, to: &current.segments)
        current.clusterEmbeddings = liveRegistry.centroids
        var keep = pinnedClusters
        for (cluster, _) in current.recognizedClusters ?? [:] {
            if let person = current.clusterAssignments[cluster] { keep[cluster] = keep[cluster] ?? person }
        }
        current.clusterAssignments = SpeakerResolver.inferClusterAssignments(
            segments: current.segments, tags: current.speakerTags, existing: keep
        )
        store.voices.recognize(in: &current)
        SpeakerResolver.resolve(&current)
        session = current
    }

    /// Live: Diese Stimme gehört dieser Person (gilt für alles, was sie sagt – auch künftig).
    func assignLiveCluster(_ cluster: Int, to personID: UUID) {
        pinnedClusters[cluster] = personID
        guard var current = session else { return }
        current.clusterAssignments[cluster] = personID
        SpeakerResolver.resolve(&current)
        session = current
    }

    // MARK: - Live-Aktionen

    var currentTime: Double { isRecording ? Date().timeIntervalSince(startDate) : elapsed }

    /// „Ab jetzt spricht …“ – `nil` = unbekannt.
    func setCurrentSpeaker(_ personID: UUID?) {
        guard isRecording, var current = session else { return }
        // Kleiner Vorlauf: Man drückt die Taste meist kurz nachdem jemand zu sprechen beginnt.
        current.tagSpeaker(personID, at: max(0, currentTime - 1.0))
        session = current
        currentSpeakerID = personID
    }

    /// „Wer war das?“ live beantwortet: Der Beitrag gehört dieser Person. War es der neueste Beitrag,
    /// spricht sie vermutlich noch – dann gilt sie ab Beginn des Beitrags als aktueller Sprecher.
    func assignTurn(segmentIDs: [UUID], start: Double, to personID: UUID, isLatest: Bool) {
        guard var current = session else { return }
        // Ist die Stimme schon erkannt, gleich die ganze Stimme zuordnen.
        let clusters = Set(current.segments.filter { segmentIDs.contains($0.id) }.compactMap(\.clusterID))
        if clusters.count == 1, let cluster = clusters.first {
            pinnedClusters[cluster] = personID
            current.clusterAssignments[cluster] = personID
        }
        current.assign(segments: segmentIDs, to: personID)
        if isLatest && isRecording {
            current.tagSpeaker(personID, at: start)
            currentSpeakerID = personID
        }
        session = current
    }

    func setSpeaker(hotkeyIndex index: Int) {
        guard let current = session else { return }
        if index == 0 { setCurrentSpeaker(nil); return }
        let people = current.hotkeyPeople
        guard index - 1 < people.count else { return }
        setCurrentSpeaker(people[index - 1].id)
    }

    /// Name eintippen → Person anlegen (falls neu) und sofort als aktuellen Sprecher setzen.
    func speakerTyped(_ name: String, partyID: UUID?) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, var current = session else { return }
        let person = current.addPerson(named: name, partyID: partyID)
        session = current
        setCurrentSpeaker(person.id)
    }

    func addMarker(_ kind: MarkerKind, text: String = "") {
        guard var current = session else { return }
        current.addMarker(kind, text: text, at: currentTime)
        session = current
    }

    func handle(_ action: GlobalHotkeys.Action) {
        switch action {
        case .speaker(let n): setSpeaker(hotkeyIndex: n)
        case .marker(.highlight): addMarker(.highlight)
        case .marker(.todo): addMarker(.todo)
        case .marker(.decision): addMarker(.decision)
        case .focusSpeakerField: focusSpeakerFieldRequest = UUID()
        case .toggleRecording:
            if isRecording { Task { await stop() } }
        }
    }

    // MARK: - Stop & Nachbearbeitung

    func stop() async {
        guard isRecording, var current = session else { return }
        phase = .finishing(String(localized: "Aufnahme wird beendet …"))
        stopTimers()
        current.duration = Date().timeIntervalSince(startDate)
        elapsed = current.duration

        systemTap.stop()
        microphone.stop()
        systemTrack?.finish()
        micTrack?.finish()
        chunkContinuation?.finish()
        liveDiarizationContinuation?.finish()
        session = current

        phase = .finishing(String(localized: "Restliche Abschnitte werden transkribiert …"))
        await transcriptionTask?.value
        await liveDiarizationTask?.value
        liveDiarizationTask = nil
        liveDiarizationContinuation = nil
        liveDiarizationActive = false
        current = session ?? current

        let folder = store.folder(for: current)
        let systemURL = folder.appendingPathComponent("system.m4a")
        let micURL = folder.appendingPathComponent("mikrofon.m4a")

        if !liveTranscriptionWorked {
            await transcribeFromFiles(&current, folder: folder) { [weak self] status in
                self?.phase = .finishing(status)
            }
        }
        await diarize(&current, systemURL: systemURL) { [weak self] status in
            self?.phase = .finishing(status)
        }

        if UserDefaults.standard.bool(forKey: SettingsKey.autoSummary), Summarizer.isAvailable, !current.segments.isEmpty {
            phase = .finishing(String(localized: "Zusammenfassung wird erstellt …"))
            do {
                current.summary = try await Summarizer.summarize(current) { [weak self] status in
                    self?.phase = .finishing(status)
                }
            } catch {
                // Kein Drama: Die Zusammenfassung lässt sich später erneut anstoßen.
            }
        }

        if UserDefaults.standard.bool(forKey: SettingsKey.saveAudio) {
            phase = .finishing(String(localized: "Audio wird zusammengeführt …"))
            let combinedURL = folder.appendingPathComponent("gesamt.m4a")
            do {
                try await AudioMixdown.combine([systemURL, micURL].filter { FileManager.default.fileExists(atPath: $0.path) }, into: combinedURL)
                current.audio.combined = "gesamt.m4a"
            } catch {
                // Einzelspuren bleiben in jedem Fall erhalten.
            }
        } else if liveTranscriptionWorked || !current.segments.isEmpty {
            // Audio nur löschen, wenn das Transkript sicher entstanden ist.
            try? FileManager.default.removeItem(at: systemURL)
            try? FileManager.default.removeItem(at: micURL)
            current.audio = AudioFiles()
        }

        current.state = .finished
        session = current
        do {
            try store.save(current)
        } catch {
            errorMessage = String(localized: "Speichern fehlgeschlagen: \(error.localizedDescription)")
        }

        systemTrack = nil
        micTrack = nil
        transcriptionTask = nil
        chunkContinuation = nil
        currentSpeakerID = nil
        micLevel = 0
        systemLevel = 0
        phase = .idle
    }

    // MARK: - Nachbearbeitung (auch für gespeicherte Gespräche)

    /// Transkribiert ein gespeichertes Gespräch aus seinen Audiodateien neu
    /// (z. B. wenn das Sprachmodell während der Aufnahme nicht bereit war).
    func retranscribe(_ id: UUID) async {
        guard reprocessing == nil, let entry = store.entries.first(where: { $0.id == id }) else { return }
        var session = entry.session
        reprocessing = (id, String(localized: "Sprachmodell wird geladen …"))
        await transcribeFromFiles(&session, folder: entry.folder) { [weak self] status in
            self?.reprocessing = (id, status)
        }
        await diarize(&session, systemURL: entry.folder.appendingPathComponent("system.m4a")) { [weak self] status in
            self?.reprocessing = (id, status)
        }
        try? store.save(session)
        reprocessing = nil
    }

    /// Zusammenfassung für ein gespeichertes Gespräch (neu) erstellen.
    func summarize(_ id: UUID) async {
        guard reprocessing == nil, let entry = store.entries.first(where: { $0.id == id }) else { return }
        var session = entry.session
        reprocessing = (id, String(localized: "Zusammenfassung wird erstellt …"))
        do {
            session.summary = try await Summarizer.summarize(session) { [weak self] status in
                self?.reprocessing = (id, status)
            }
            try? store.save(session)
        } catch {
            errorMessage = error.localizedDescription
        }
        reprocessing = nil
    }

    private func transcribeFromFiles(_ session: inout Session, folder: URL, status: (String) -> Void) async {
        status(String(localized: "Sprachmodell wird geladen …"))
        guard await models.ensureReady() else {
            errorMessage = String(localized: "Das Sprachmodell ist nicht verfügbar. Die Aufnahme ist gespeichert – du kannst sie später über „Transkribieren“ nachholen.")
            return
        }
        let language = session.language
        var segments: [TranscriptSegment] = []
        let tracks: [(AudioSource, String?, String)] = [
            (.microphone, session.audio.microphone, String(localized: "dein Mikrofon")),
            (.system, session.audio.system, String(localized: "die Gegenseite"))
        ]
        for (source, name, label) in tracks {
            guard let name else { continue }
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            status(String(localized: "Transkribiere \(label) …"))
            do {
                segments += try await models.engine.transcribeFile(url, source: source, language: language) { _ in }
            } catch {
                errorMessage = String(localized: "Transkription fehlgeschlagen: \(error.localizedDescription)")
            }
        }
        guard !segments.isEmpty else { return }
        session.segments = segments.sorted { $0.start < $1.start }
        SpeakerResolver.resolve(&session)
    }

    private func diarize(_ session: inout Session, systemURL: URL, status: (String) -> Void) async {
        guard UserDefaults.standard.bool(forKey: SettingsKey.runDiarization),
              session.segments.contains(where: { $0.source == .system }),
              FileManager.default.fileExists(atPath: systemURL.path) else { return }
        status(String(localized: "Stimmen werden erkannt …"))
        do {
            let samples = try await Task.detached(priority: .userInitiated) {
                try AudioMixdown.loadMono16k(systemURL)
            }.value
            let output = try await diarizer.diarize(samples: samples, expectedSpeakers: nil)
            // Stimm-Fingerabdrücke gehören zu den Cluster-Nummern dieses Laufs.
            session.clusterAssignments = [:]
            session.recognizedClusters = nil
            for index in session.segments.indices { session.segments[index].clusterID = nil }
            session.clusterEmbeddings = output.embeddings.isEmpty ? nil : output.embeddings
            // Erst deine Live-Zuordnungen, dann bekannte Stimmen für alles, was noch offen ist.
            SpeakerResolver.finalize(&session, turns: output.turns)
            let recognized = store.voices.recognize(in: &session)
            if !recognized.isEmpty {
                lastRecognizedNames = recognized
            }
        } catch {
            errorMessage = String(localized: "Stimmenerkennung fehlgeschlagen: \(error.localizedDescription). Deine Live-Zuordnungen bleiben erhalten.")
        }
    }

    // MARK: - Intern

    private func fail(_ message: String) {
        errorMessage = message
        systemTrack = nil
        micTrack = nil
        chunkContinuation?.finish()
        chunkContinuation = nil
        liveDiarizationContinuation?.finish()
        liveDiarizationContinuation = nil
        phase = .idle
    }

    private func startSystemTap() throws {
        let systemRecorder = systemTrack
        try systemTap.start(target: systemTarget) { buffer in systemRecorder?.append(buffer) }
    }

    /// Prüft alle paar Sekunden, ob beide Spuren noch Ton liefern.
    private func checkAudio() {
        guard isRecording else { return }
        // Systemton: Der Tap liefert auch bei Stille laufend Daten. Bleiben sie aus, hängt das
        // Gerät (z. B. Bluetooth-Moduswechsel) – dann Tap und Aggregate neu aufbauen.
        if systemTap.secondsSinceLastBuffer > 4 {
            systemTap.stop()
            systemRestarts += 1
            do {
                try startSystemTap()
                if systemRestarts >= 3 {
                    audioWarning = String(localized: "Der Systemton reißt immer wieder ab. Wähle als Ausgabe die Mac-Lautsprecher oder Kopfhörer statt eines Bluetooth-Lautsprechers.")
                }
            } catch {
                audioWarning = String(localized: "Systemton konnte nicht neu gestartet werden: \(error.localizedDescription)")
            }
        }
        // Mikrofon: Ein echtes Mikro rauscht immer ein wenig. Absolute Stille heißt, es kommt nichts an.
        if micTrack != nil, Date().timeIntervalSince(lastMicSound) > 10 {
            let echo = UserDefaults.standard.bool(forKey: SettingsKey.voiceProcessing)
            audioWarning = echo
                ? String(localized: "Dein Mikrofon liefert keinen Ton. Das passiert oft mit Echounterdrückung und Bluetooth-Geräten. Schalte sie in den Einstellungen aus oder wähle ein anderes Mikrofon.")
                : String(localized: "Dein Mikrofon liefert keinen Ton. Prüfe, ob das richtige Mikrofon ausgewählt und nicht stummgeschaltet ist.")
        } else if audioWarning != nil, micTrack == nil || Date().timeIntervalSince(lastMicSound) < 2, systemRestarts < 3 {
            audioWarning = nil
        }
    }

    private func startTimers() {
        lastMicSound = Date()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAudio() }
        }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.elapsed = Date().timeIntervalSince(self.startDate)
            }
        }
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording, var current = self.session else { return }
                current.duration = self.elapsed
                _ = try? self.store.save(current, writeMarkdown: true)
            }
        }
    }

    private func stopTimers() {
        clockTimer?.invalidate()
        autosaveTimer?.invalidate()
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        audioWarning = nil
        clockTimer = nil
        autosaveTimer = nil
    }
}
