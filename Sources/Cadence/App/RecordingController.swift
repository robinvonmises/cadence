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
    private var startDate = Date()
    private var liveTranscriptionWorked = true

    init(store: SessionStore, models: ModelManager) {
        self.store = store
        self.models = models
    }

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { phase != .idle }

    // MARK: - Start

    func start(title: String, target: SystemAudioTarget, consentConfirmed: Bool) async {
        guard phase == .idle else { return }
        phase = .preparing
        errorMessage = nil

        let defaults = UserDefaults.standard
        guard await MicrophoneCapture.requestPermission() else {
            fail("Kein Zugriff auf das Mikrofon. Bitte in Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon erlauben.")
            return
        }

        var newSession = Session.new(
            title: title.isEmpty ? "Gespräch" : title,
            ownerName: defaults.string(forKey: SettingsKey.ownerName) ?? Defaults.ownerName,
            parties: [
                Party(name: defaults.string(forKey: SettingsKey.ownPartyName) ?? "Wir", color: .blue),
                Party(name: defaults.string(forKey: SettingsKey.otherPartyName) ?? "Kunde", color: .orange)
            ]
        )
        newSession.sourceDescription = target.label
        let language = LanguageOption(rawValue: defaults.string(forKey: SettingsKey.language) ?? "de") ?? .german
        newSession.language = language.whisperCode
        newSession.consentConfirmed = consentConfirmed
        newSession.audio = AudioFiles(system: "system.m4a", microphone: "mikrofon.m4a")
        if consentConfirmed {
            newSession.addMarker(.consent, text: "Einwilligung zur Aufzeichnung bestätigt", at: 0)
        }

        newSession.startedAt = Date()
        let folder: URL
        do {
            folder = try store.save(newSession, writeMarkdown: false)
        } catch {
            fail("Speicherort nicht beschreibbar: \(error.localizedDescription)")
            return
        }
        do {
            systemTrack = try AudioTrackRecorder(source: .system, fileURL: folder.appendingPathComponent("system.m4a"))
            micTrack = try AudioTrackRecorder(source: .microphone, fileURL: folder.appendingPathComponent("mikrofon.m4a"))
        } catch {
            store.delete(newSession.id)
            fail("Audiodateien konnten nicht angelegt werden: \(error.localizedDescription)")
            return
        }

        // Abschnitte beider Spuren landen in einer gemeinsamen Warteschlange.
        let (stream, continuation) = AsyncStream<SpeechChunk>.makeStream()
        chunkContinuation = continuation
        for track in [systemTrack, micTrack].compactMap({ $0 }) {
            let source = track.source
            track.onChunk = { chunk in continuation.yield(chunk) }
            track.onLevel = { [weak self] level in
                Task { @MainActor in
                    guard let self else { return }
                    if source == .system { self.systemLevel = level } else { self.micLevel = level }
                }
            }
        }

        do {
            let systemRecorder = systemTrack
            try systemTap.start(target: target) { buffer in systemRecorder?.append(buffer) }
        } catch {
            store.delete(newSession.id)
            fail("Systemaudio konnte nicht aufgenommen werden: \(error.localizedDescription)\n\nPrüfe Systemeinstellungen → Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme.")
            return
        }
        do {
            let voiceProcessing = defaults.bool(forKey: SettingsKey.voiceProcessing)
            let micRecorder = micTrack
            try microphone.start(voiceProcessing: voiceProcessing) { buffer in micRecorder?.append(buffer) }
        } catch {
            systemTap.stop()
            store.delete(newSession.id)
            fail("Mikrofon konnte nicht gestartet werden: \(error.localizedDescription)")
            return
        }

        startDate = Date()
        session = newSession
        currentSpeakerID = nil
        elapsed = 0
        phase = .recording
        startTimers()

        liveTranscriptionWorked = true
        transcriptionTask = Task { [weak self] in
            await self?.runTranscription(stream: stream, language: language.whisperCode)
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
        phase = .finishing("Aufnahme wird beendet …")
        stopTimers()
        current.duration = Date().timeIntervalSince(startDate)
        elapsed = current.duration

        systemTap.stop()
        microphone.stop()
        systemTrack?.finish()
        micTrack?.finish()
        chunkContinuation?.finish()
        session = current

        phase = .finishing("Restliche Abschnitte werden transkribiert …")
        await transcriptionTask?.value
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

        if UserDefaults.standard.bool(forKey: SettingsKey.saveAudio) {
            phase = .finishing("Audio wird zusammengeführt …")
            let combinedURL = folder.appendingPathComponent("gesamt.m4a")
            do {
                try await AudioMixdown.combine([systemURL, micURL], into: combinedURL)
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
            errorMessage = "Speichern fehlgeschlagen: \(error.localizedDescription)"
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
        reprocessing = (id, "Sprachmodell wird geladen …")
        await transcribeFromFiles(&session, folder: entry.folder) { [weak self] status in
            self?.reprocessing = (id, status)
        }
        await diarize(&session, systemURL: entry.folder.appendingPathComponent("system.m4a")) { [weak self] status in
            self?.reprocessing = (id, status)
        }
        try? store.save(session)
        reprocessing = nil
    }

    private func transcribeFromFiles(_ session: inout Session, folder: URL, status: (String) -> Void) async {
        status("Sprachmodell wird geladen …")
        guard await models.ensureReady() else {
            errorMessage = "Das Sprachmodell ist nicht verfügbar. Die Aufnahme ist gespeichert – du kannst sie später über „Transkribieren“ nachholen."
            return
        }
        let language = session.language
        var segments: [TranscriptSegment] = []
        let tracks: [(AudioSource, String?, String)] = [
            (.microphone, session.audio.microphone, "dein Mikrofon"),
            (.system, session.audio.system, "die Gegenseite")
        ]
        for (source, name, label) in tracks {
            guard let name else { continue }
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            status("Transkribiere \(label) …")
            do {
                segments += try await models.engine.transcribeFile(url, source: source, language: language) { _ in }
            } catch {
                errorMessage = "Transkription fehlgeschlagen: \(error.localizedDescription)"
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
        status("Stimmen werden erkannt …")
        do {
            let samples = try await Task.detached(priority: .userInitiated) {
                try AudioMixdown.loadMono16k(systemURL)
            }.value
            let turns = try await diarizer.diarize(samples: samples, expectedSpeakers: nil)
            SpeakerResolver.finalize(&session, turns: turns)
        } catch {
            errorMessage = "Stimmenerkennung fehlgeschlagen: \(error.localizedDescription). Deine Live-Zuordnungen bleiben erhalten."
        }
    }

    // MARK: - Intern

    private func fail(_ message: String) {
        errorMessage = message
        systemTrack = nil
        micTrack = nil
        chunkContinuation?.finish()
        chunkContinuation = nil
        phase = .idle
    }

    private func startTimers() {
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
        clockTimer = nil
        autosaveTimer = nil
    }
}
