import AVFoundation
import CadenceCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Live

struct LiveSessionView: View {
    @EnvironmentObject private var recorder: RecordingController
    @State private var showInspector = true

    private var sessionBinding: Binding<Session> {
        Binding(
            get: { recorder.session ?? Session(title: "") },
            set: { recorder.session = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            liveHeader
            ModelStatusBanner(duringRecording: true)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            Divider()
            TranscriptView(session: sessionBinding, isLive: true)
            if recorder.isRecording {
                Divider()
                SpeakerDock(session: sessionBinding)
            }
        }
        .inspector(isPresented: $showInspector) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PartiesPanel(session: sessionBinding)
                    MarkersPanel(session: sessionBinding, currentTime: { recorder.currentTime })
                }
                .padding(16)
            }
            .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Seitenleiste", systemImage: "sidebar.right")
                }
            }
        }
    }

    private var liveHeader: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Titel", text: sessionBinding.title)
                    .textFieldStyle(.plain)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                HStack(spacing: 8) {
                    if recorder.isRecording {
                        Circle().fill(Theme.record).frame(width: 9, height: 9)
                            .modifier(PulseModifier())
                        Text("REC").font(.caption.weight(.heavy)).foregroundStyle(Theme.record)
                    }
                    Text(recorder.session?.sourceDescription ?? "")
                    if recorder.backlog > 1 {
                        Text("· \(recorder.backlog) Abschnitte warten").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 14) {
                meter("mic.fill", "Du", recorder.micLevel, PartyColor.blue.color)
                meter("speaker.wave.2.fill", "Gegenseite", recorder.systemLevel, PartyColor.orange.color)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.background.secondary, in: Capsule())

            Text(TimeFormat.clock(recorder.elapsed))
                .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
                .frame(minWidth: 86, alignment: .trailing)

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
                        .font(.headline)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.record)
                .controlSize(.large)
                .clipShape(Capsule())
                .keyboardShortcut(".", modifiers: .command)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func meter(_ icon: String, _ label: String, _ level: Float, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            LevelBars(level: level, color: color)
        }
        .help(label)
    }
}

private struct PulseModifier: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

// MARK: - Gespeichert

struct SavedSessionView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var recorder: RecordingController
    let entry: SessionStore.Entry

    @State private var draft: Session
    @State private var search = ""
    @StateObject private var player = AudioPlayer()
    @State private var exportError: String?
    @State private var showInspector = true

    init(entry: SessionStore.Entry) {
        self.entry = entry
        _draft = State(initialValue: entry.session)
    }

    private var hasAudio: Bool {
        [draft.audio.system, draft.audio.microphone].contains { name in
            store.audioURL(name, in: draft) != nil
        }
    }

    private var reprocessStatus: String? {
        guard let job = recorder.reprocessing, job.id == draft.id else { return nil }
        return job.status
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let reprocessStatus {
                Banner(kind: .info, title: reprocessStatus, message: "Du kannst Cadence währenddessen normal weiterbenutzen.", progress: nil)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            } else if draft.segments.isEmpty && hasAudio {
                Banner(kind: .warning, title: "Dieses Gespräch ist noch nicht transkribiert",
                       message: "Die Aufnahme ist gespeichert. Cadence kann sie jetzt nachträglich transkribieren.") {
                    Button("Jetzt transkribieren") {
                        Task { await recorder.retranscribe(draft.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(recorder.isBusy)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            Divider()
            TranscriptView(
                session: $draft,
                isLive: false,
                filter: search,
                onSeek: player.isAvailable ? { player.play(from: $0) } : nil,
                playingTime: player.isPlaying ? player.currentTime : nil
            )
            if player.isAvailable {
                Divider()
                PlayerBar(player: player, duration: draft.duration)
            }
        }
        .inspector(isPresented: $showInspector) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ClusterMappingPanel(session: $draft, onListen: player.isAvailable ? { player.play(from: $0, duration: 6) } : nil)
                    PartiesPanel(session: $draft)
                    MarkersPanel(session: $draft, currentTime: { player.currentTime }, onSeek: { player.play(from: $0) })
                    statistics
                }
                .padding(16)
            }
            .inspectorColumnWidth(min: 260, ideal: 310, max: 420)
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.label) { export(format) }
                    }
                    Divider()
                    Button("Protokoll in die Zwischenablage") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SessionExporter(session: draft).protocolMarkdown(), forType: .string)
                    }
                    if hasAudio && !draft.segments.isEmpty {
                        Divider()
                        Button("Neu transkribieren") { Task { await recorder.retranscribe(draft.id) } }
                            .disabled(recorder.isBusy || recorder.reprocessing != nil)
                    }
                } label: {
                    Label("Exportieren", systemImage: "square.and.arrow.up")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.folder])
                } label: {
                    Label("Im Finder zeigen", systemImage: "folder")
                }
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Seitenleiste", systemImage: "sidebar.right")
                }
            }
        }
        .searchable(text: $search, prompt: "Im Transkript suchen")
        .onAppear { player.load(store.audioURL(draft.audio.combined ?? draft.audio.system, in: draft)) }
        .onDisappear { player.stop() }
        .onChange(of: draft) { _, newValue in
            _ = try? store.save(newValue)
        }
        .onChange(of: entry.session) { _, newValue in
            // Übernimmt Ergebnisse einer Nachbearbeitung (z. B. nachträgliche Transkription).
            if newValue != draft { draft = newValue }
        }
        .alert("Export fehlgeschlagen", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Titel", text: $draft.title)
                .textFieldStyle(.plain)
                .font(.system(.title2, design: .rounded).weight(.bold))
            HStack(spacing: 8) {
                InfoPill(icon: "calendar", text: draft.startedAt.formatted(date: .abbreviated, time: .shortened))
                InfoPill(icon: "clock", text: TimeFormat.duration(draft.duration))
                InfoPill(icon: "person.2", text: "\(draft.people.count) Personen")
                if !draft.markers.isEmpty {
                    InfoPill(icon: "star", text: "\(draft.markers.count) Marker")
                }
                if draft.consentConfirmed {
                    InfoPill(icon: "checkmark.shield", text: "Einwilligung")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var statistics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Redeanteile").sectionTitle()
            let speaking = draft.speakingTime()
            let total = max(1, speaking.reduce(0) { $0 + $1.seconds })
            ForEach(speaking, id: \.name) { item in
                let person = draft.people.first { $0.name == item.name }
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.name).font(.callout).lineLimit(1)
                        Spacer()
                        Text("\(Int((item.seconds / total * 100).rounded())) %")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(draft.color(for: person?.id).gradient)
                                .frame(width: max(4, geo.size.width * item.seconds / total))
                        }
                    }
                    .frame(height: 6)
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

private struct InfoPill: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.background.secondary, in: Capsule())
    }
}

private struct PlayerBar: View {
    @ObservedObject var player: AudioPlayer
    let duration: Double

    var body: some View {
        HStack(spacing: 14) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.gradient)
            }
            .buttonStyle(.plain)

            Text(TimeFormat.clock(player.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            Slider(value: Binding(
                get: { player.currentTime },
                set: { player.seek(to: $0) }
            ), in: 0...max(1, player.duration > 0 ? player.duration : duration))
            .tint(Theme.accent)
            Text(TimeFormat.clock(player.duration > 0 ? player.duration : duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
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
    var duration: Double { player?.duration ?? 0 }

    func load(_ url: URL?) {
        guard let url else { player = nil; return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
    }

    func play(from time: Double, duration: Double? = nil) {
        guard let player else { return }
        player.currentTime = max(0, time - 0.3)
        currentTime = player.currentTime
        stopAt = duration.map { time + $0 }
        player.play()
        isPlaying = true
        startTimer()
    }

    func seek(to time: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        currentTime = player.currentTime
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
