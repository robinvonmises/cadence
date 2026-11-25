import AVFoundation
import CadenceCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Live

struct LiveSessionView: View {
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var models: ModelManager

    private var sessionBinding: Binding<Session> {
        Binding(
            get: { recorder.session ?? Session(title: "") },
            set: { recorder.session = $0 }
        )
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                liveHeader
                TranscriptView(session: sessionBinding, isLive: true)
            }
            .frame(minWidth: 480)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LiveSpeakerPanel(session: sessionBinding).card()
                    MarkersPanel(session: sessionBinding, currentTime: { recorder.currentTime }).card()
                    PartiesPanel(session: sessionBinding).card()
                }
                .padding(14)
            }
            .frame(minWidth: 300, idealWidth: 350, maxWidth: 460)
        }
        .disabled(!recorder.isRecording && recorder.phase == .idle)
    }

    private var liveHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Titel", text: sessionBinding.title)
                        .textFieldStyle(.plain)
                        .font(.title2.bold())
                    HStack(spacing: 8) {
                        recordingPill
                        if let source = recorder.session?.sourceDescription, !source.isEmpty {
                            StatusPill(text: source, systemImage: "speaker.wave.2")
                        }
                        if recorder.backlog > 1 {
                            StatusPill(text: "\(recorder.backlog) Abschnitte in Arbeit", systemImage: "text.badge.plus", tint: Brand.indigo)
                        }
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .leading, spacing: 4) {
                    LevelMeter(label: "Mikrofon (du)", systemImage: "mic.fill", level: recorder.micLevel, tint: .blue)
                    LevelMeter(label: "Systemaudio (Gegenseite)", systemImage: "speaker.wave.2.fill", level: recorder.systemLevel, tint: .orange)
                }
                Button {
                    recorder.addMarker(.highlight)
                } label: {
                    Label("Markieren", systemImage: "star.fill")
                }
                .controlSize(.large)
                .help("Wichtige Stelle markieren (\(GlobalHotkeys.modifierSymbol)M)")
                .disabled(!recorder.isRecording)

                if case .finishing(let status) = recorder.phase {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        Task { await recorder.stop() }
                    } label: {
                        Label("Beenden", systemImage: "stop.fill")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.record)
                    .controlSize(.large)
                    .keyboardShortcut(".", modifiers: .command)
                }
            }
            if models.status != .ready {
                ModelStatusView()
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                if models.status.isWorking {
                    Text("Die Aufnahme läuft bereits – alles Gesagte wird transkribiert, sobald das Modell bereit ist.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var recordingPill: some View {
        HStack(spacing: 6) {
            Circle().fill(Brand.record).frame(width: 8, height: 8)
                .opacity(recorder.isRecording ? 1 : 0.4)
                .symbolEffect(.pulse, isActive: recorder.isRecording)
            Text(TimeFormat.clock(recorder.elapsed))
                .font(.system(.callout, design: .rounded).monospacedDigit().weight(.semibold))
        }
        .foregroundStyle(Brand.record)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Brand.record.opacity(0.12), in: Capsule())
    }
}

// MARK: - Gespeichert

struct SavedSessionView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var models: ModelManager
    let entry: SessionStore.Entry

    @State private var draft: Session
    @State private var search = ""
    @StateObject private var player = AudioPlayer()
    @State private var exportError: String?
    @State private var transcribing: Double?

    init(entry: SessionStore.Entry) {
        self.entry = entry
        _draft = State(initialValue: entry.session)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                if draft.segments.isEmpty, hasAudio {
                    retranscribeBanner
                }
                TranscriptView(
                    session: $draft,
                    isLive: false,
                    filter: search,
                    onSeek: player.isAvailable ? { player.play(from: $0) } : nil,
                    playingTime: player.isPlaying ? player.currentTime : nil
                )
            }
            .frame(minWidth: 480)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !draft.clusterIDs.isEmpty {
                        ClusterMappingPanel(session: $draft, onListen: player.isAvailable ? { player.play(from: $0, duration: 6) } : nil).card()
                    }
                    if !draft.speakingTime().isEmpty {
                        statistics.card()
                    }
                    PartiesPanel(session: $draft).card()
                    MarkersPanel(session: $draft, currentTime: { player.currentTime }, onSeek: { player.play(from: $0) }).card()
                }
                .padding(14)
            }
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
        }
        .searchable(text: $search, prompt: "Im Transkript suchen")
        .onAppear { player.load(store.audioURL(draft.audio.combined ?? draft.audio.system, in: draft)) }
        .onDisappear { player.stop() }
        .onChange(of: draft) { _, newValue in
            _ = try? store.save(newValue)
        }
        .alert("Hinweis", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Titel", text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                HStack(spacing: 8) {
                    StatusPill(text: draft.startedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    StatusPill(text: TimeFormat.duration(draft.duration), systemImage: "clock")
                    if !draft.sourceDescription.isEmpty {
                        StatusPill(text: draft.sourceDescription, systemImage: "speaker.wave.2")
                    }
                }
            }
            Spacer()
            if player.isAvailable {
                HStack(spacing: 8) {
                    Button {
                        player.toggle()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Brand.gradient, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(player.isPlaying ? "Pause" : "Abspielen")
                    Text(TimeFormat.clock(player.currentTime))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.trailing, 4)
            }
            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.label) { export(format) }
                }
                Divider()
                Button("Protokoll in Zwischenablage") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SessionExporter(session: draft).protocolMarkdown(), forType: .string)
                }
            } label: {
                Label("Exportieren", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            .controlSize(.large)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([entry.folder])
            } label: {
                Image(systemName: "folder")
            }
            .controlSize(.large)
            .help("Im Finder zeigen")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var hasAudio: Bool {
        [draft.audio.system, draft.audio.microphone].compactMap { store.audioURL($0, in: draft) }
            .contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Kein Transkript, aber Audio vorhanden (z. B. Modell fehlte bei der Aufnahme) → nachholen.
    private var retranscribeBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.badge.plus")
                .font(.title3)
                .foregroundStyle(Brand.violet)
            VStack(alignment: .leading, spacing: 2) {
                Text("Noch kein Transkript").font(.callout.weight(.semibold))
                Text("Die Aufnahme ist gespeichert. Cadence kann das Transkript jetzt aus dem Audio erstellen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let transcribing {
                ProgressView(value: transcribing > 0 ? transcribing : nil)
                    .frame(width: 120)
                Text(models.status == .ready ? "\(Int(transcribing * 100)) %" : models.statusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Button("Transkript erstellen", action: retranscribe)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(Brand.violet.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private func retranscribe() {
        let files: [(AudioSource, URL)] = [
            draft.audio.system.flatMap { store.audioURL($0, in: draft) }.map { (.system, $0) },
            draft.audio.microphone.flatMap { store.audioURL($0, in: draft) }.map { (.microphone, $0) }
        ].compactMap { $0 }
        transcribing = 0
        Task {
            do {
                let segments = try await models.transcribe(files: files, language: draft.language) { progress in
                    transcribing = progress
                }
                var updated = draft
                updated.segments = segments.sorted { $0.start < $1.start }
                SpeakerResolver.resolve(&updated)
                draft = updated
                if segments.isEmpty { exportError = "Im Audio wurde keine Sprache erkannt." }
            } catch {
                exportError = "Transkription fehlgeschlagen: \(error.localizedDescription)"
            }
            transcribing = nil
        }
    }

    private var statistics: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Redeanteile", systemImage: "chart.bar.fill")
            let speaking = draft.speakingTime()
            let total = max(1, speaking.reduce(0) { $0 + $1.seconds })
            ForEach(speaking, id: \.name) { entry in
                HStack {
                    Text(entry.name).frame(width: 110, alignment: .leading).lineLimit(1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.06))
                            Capsule().fill(Brand.gradient)
                                .frame(width: geo.size.width * entry.seconds / total)
                        }
                    }
                    .frame(height: 8)
                    Text("\(Int((entry.seconds / total * 100).rounded())) %")
                        .font(.caption.monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    private func export(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(draft.title) – \(format.defaultFileName)"
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SessionExporter(session: draft).export(format).write(to: url, options: .atomic)
        } catch {
            exportError = error.localizedDescription
        }
    }
}

// MARK: - Wiedergabe

@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var stopAt: Double?

    var isAvailable: Bool { player != nil }

    func load(_ url: URL?) {
        guard let url else { player = nil; return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
    }

    func play(from time: Double, duration: Double? = nil) {
        guard let player else { return }
        player.currentTime = max(0, time - 0.3)
        stopAt = duration.map { time + $0 }
        player.play()
        isPlaying = true
        startTimer()
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            stopAt = nil
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func stop() {
        player?.stop()
        isPlaying = false
        timer?.invalidate()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if let stopAt = self.stopAt, player.currentTime >= stopAt {
                    player.pause()
                    self.stopAt = nil
                }
                if !player.isPlaying {
                    self.isPlaying = false
                    self.timer?.invalidate()
                }
            }
        }
    }
}
