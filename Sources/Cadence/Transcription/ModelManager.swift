import CadenceCore
import Foundation
import WhisperKit

/// Lädt das Sprachmodell einmal pro App-Start – mit sichtbarem Fortschritt – und hält es für
/// alle Aufnahmen bereit.
///
/// Modelle liegen bewusst unter `~/Library/Application Support/Cadence/Models` und nicht im
/// Standardort von WhisperKit (`~/Documents/huggingface`): Ist „Dokumente“ mit einer Cloud
/// synchronisiert (Nextcloud, iCloud …), benennt der Sync-Client halb geladene Ordner um und der
/// Download bricht mit „konnte nicht nach weights bewegt werden“ ab.
@MainActor
final class ModelManager: ObservableObject {
    enum Status: Equatable {
        case idle
        case downloading(Double)
        case loading
        case ready
        case failed(String)

        var isWorking: Bool {
            switch self {
            case .downloading, .loading: return true
            default: return false
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var modelName: String = ""

    let engine = TranscriptionEngine()
    private var task: Task<Void, Never>?

    nonisolated static var modelsFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Cadence/Models", isDirectory: true)
    }

    var currentOption: WhisperModelOption? { WhisperModelOption(rawValue: modelName) }

    /// Kurzer Statustext für die Oberfläche.
    var statusText: String {
        let name = currentOption?.shortName ?? "Sprachmodell"
        switch status {
        case .idle: return "\(name) wird vorbereitet"
        case .downloading(let progress):
            return progress > 0 ? "\(name) wird geladen – \(Int(progress * 100)) %" : "\(name) wird heruntergeladen …"
        case .loading: return "\(name) wird gestartet …"
        case .ready: return "\(name) bereit"
        case .failed: return "\(name) konnte nicht geladen werden"
        }
    }

    /// Modell aus den Einstellungen laden (falls noch nicht geschehen).
    func prepareSelectedModel() {
        let model = UserDefaults.standard.string(forKey: SettingsKey.model) ?? WhisperModelOption.largeTurbo.rawValue
        prepare(model: model)
    }

    func prepare(model: String) {
        if modelName == model, status == .ready || task != nil { return }
        task?.cancel()
        modelName = model
        status = .downloading(0)
        task = Task { [weak self] in
            await self?.run(model: model)
        }
    }

    func retry() {
        let model = modelName.isEmpty ? (UserDefaults.standard.string(forKey: SettingsKey.model) ?? WhisperModelOption.largeTurbo.rawValue) : modelName
        task?.cancel()
        task = nil
        status = .idle
        prepare(model: model)
    }

    /// Wartet, bis das Modell bereit ist (startet das Laden bei Bedarf). `false` bei Fehler.
    func waitUntilReady() async -> Bool {
        if status == .ready { return true }
        if task == nil { prepareSelectedModel() }
        while let running = task {
            await running.value
            if task == running { break }
        }
        return status == .ready
    }

    private func run(model: String) async {
        let base = Self.modelsFolder
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        do {
            let folder: URL
            do {
                folder = try await WhisperKit.download(variant: model, downloadBase: base) { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        guard let self, self.modelName == model, case .downloading = self.status else { return }
                        self.status = .downloading(fraction)
                    }
                }
            } catch {
                // Offline? Dann ein vollständig vorhandenes Modell verwenden.
                guard let local = Self.completeLocalModel(model, base: base) else { throw error }
                folder = local
            }
            try Task.checkCancellation()
            status = .loading
            try await engine.load(model: model, folder: folder, downloadBase: base)
            try Task.checkCancellation()
            status = .ready
        } catch is CancellationError {
            return
        } catch {
            if modelName == model { status = .failed(error.localizedDescription) }
        }
        if modelName == model { task = nil }
    }

    private static func completeLocalModel(_ model: String, base: URL) -> URL? {
        let folder = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model)")
        let required = ["AudioEncoder", "TextDecoder", "MelSpectrogram"].map {
            folder.appendingPathComponent("\($0).mlmodelc/weights/weight.bin")
        }
        return required.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } ? folder : nil
    }

    // MARK: - Nachträglich transkribieren

    /// Transkribiert gespeicherte Spuren (z. B. wenn das Modell während der Aufnahme fehlte).
    func transcribe(files: [(AudioSource, URL)], language: String?, progress: @escaping @MainActor (Double) -> Void) async throws -> [TranscriptSegment] {
        guard await waitUntilReady() else {
            throw NSError(domain: "Cadence", code: 1, userInfo: [NSLocalizedDescriptionKey: statusText])
        }
        var chunks: [SpeechChunk] = []
        for (source, url) in files where FileManager.default.fileExists(atPath: url.path) {
            let samples = try await Task.detached(priority: .userInitiated) { try AudioMixdown.loadMono16k(url) }.value
            var chunker = SpeechChunker(source: source)
            chunks += chunker.append(samples)
            if let last = chunker.flush() { chunks.append(last) }
        }
        var segments: [TranscriptSegment] = []
        for (index, chunk) in chunks.enumerated() {
            segments += await engine.transcribe(chunk, language: language)
            progress(Double(index + 1) / Double(max(chunks.count, 1)))
        }
        return segments
    }
}
