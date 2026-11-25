import AVFoundation
import CadenceCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Live

struct LiveSessionView: View {
    @EnvironmentObject private var recorder: RecordingController

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
                Divider()
                TranscriptView(session: sessionBinding, isLive: true)
            }
            .frame(minWidth: 480)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    LiveSpeakerPanel(session: sessionBinding)
                    Divider()
                    MarkersPanel(session: sessionBinding, currentTime: { recorder.currentTime })
                    Divider()
                    PartiesPanel(session: sessionBinding)
                }
                .padding(16)
            }
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
        }
        .disabled(!recorder.isRecording && recorder.phase == .idle)
    }

    private var liveHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Titel", text: sessionBinding.title)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        .symbolEffect(.pulse, isActive: recorder.isRecording)
                    Text(TimeFormat.clock(recorder.elapsed)).monospacedDigit()
                    Text("· \(recorder.session?.sourceDescription ?? "")").foregroundStyle(.secondary)
                    if recorder.backlog > 1 {
                        Text("· \(recorder.backlog) Abschnitte in der Warteschlange").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                if !recorder.modelStatus.isEmpty {
                    Label(recorder.modelStatus, systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                LevelMeter(label: "Mikrofon (du)", systemImage: "mic.fill", level: recorder.micLevel)
                LevelMeter(label: "Systemaudio (Gegenseite)", systemImage: "speaker.wave.2.fill", level: recorder.systemLevel)
            }
            Button {
                recorder.addMarker(.highlight)
            } label: {
                Label("Markieren", systemImage: "star")
            }
            .help("Wichtige Stelle markieren (\(GlobalHotkeys.modifierSymbol)M)")
            .disabled(!recorder.isRecording)

            if case .finishing(let status) = recorder.phase {
                ProgressView().controlSize(.small)
                Text(status).font(.callout).foregroundStyle(.secondary)
            } else {
                Button(role: .destructive) {
                    Task { await recorder.stop() }
                } label: {
                    Label("Beenden", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .keyboardShortcut(".", modifiers: .command)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Gespeichert

struct SavedSessionView: View {
    @EnvironmentObject private var store: SessionStore
    let entry: SessionStore.Entry

    @State private var draft: Session
    @State private var search = ""
    @StateObject private var player = AudioPlayer()
    @State private var exportError: String?

    init(entry: SessionStore.Entry) {
        self.entry = entry
        _draft = State(initialValue: entry.session)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                Divider()
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
                VStack(alignment: .leading, spacing: 22) {
                    ClusterMappingPanel(session: $draft, onListen: player.isAvailable ? { player.play(from: $0, duration: 6) } : nil)
                    PartiesPanel(session: $draft)
                    Divider()
                    MarkersPanel(session: $draft, currentTime: { player.currentTime }, onSeek: { player.play(from: $0) })
                    Divider()
                    statistics
                }
                .padding(16)
            }
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
        }
        .searchable(text: $search, prompt: "Im Transkript suchen")
        .onAppear { player.load(store.audioURL(draft.audio.combined ?? draft.audio.system, in: draft)) }
        .onDisappear { player.stop() }
        .onChange(of: draft) { _, newValue in
            _ = try? store.save(newValue)
        }
        .alert("Export fehlgeschlagen", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Titel", text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                Text("\(draft.startedAt.formatted(date: .complete, time: .shortened)) · \(TimeFormat.duration(draft.duration)) · \(draft.sourceDescription)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if player.isAvailable {
                Button {
                    player.toggle()
                } label: {
                    Label(player.isPlaying ? "Pause" : "Abspielen", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                }
                Text(TimeFormat.clock(player.currentTime)).monospacedDigit().foregroundStyle(.secondary)
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
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([entry.folder])
            } label: {
                Label("Ordner", systemImage: "folder")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var statistics: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Redeanteile").font(.headline)
            let speaking = draft.speakingTime()
            let total = max(1, speaking.reduce(0) { $0 + $1.seconds })
            ForEach(speaking, id: \.name) { entry in
                HStack {
                    Text(entry.name).frame(width: 110, alignment: .leading).lineLimit(1)
                    GeometryReader { geo in
                        Capsule().fill(Color.accentColor.opacity(0.6))
                            .frame(width: geo.size.width * entry.seconds / total)
                    }
                    .frame(height: 6)
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
