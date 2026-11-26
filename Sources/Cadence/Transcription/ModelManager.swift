import CadenceCore
import Foundation

/// Hält das Whisper-Modell bereit und zeigt den Ladezustand in der Oberfläche an.
/// Das Modell wird schon beim App-Start geladen, damit es beim ersten Gespräch bereit ist.
@MainActor
final class ModelManager: ObservableObject {
    enum Status: Equatable {
        case idle
        case downloading(Double)
        case loading
        /// Modell liegt schon auf dem Mac und wird nur geladen – kein Hinweis nötig.
        case warmingUp
        case ready
        case failed(String)

        var isWorking: Bool {
            switch self {
            case .downloading, .loading, .warmingUp: return true
            default: return false
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var errorDetails: String?

    let engine = TranscriptionEngine()
    private var loadTask: Task<Bool, Never>?

    var modelName: String {
        UserDefaults.standard.string(forKey: SettingsKey.model) ?? WhisperModelOption.largeTurbo.rawValue
    }

    var modelLabel: String {
        WhisperModelOption(rawValue: modelName)?.shortLabel ?? modelName
    }

    var isReady: Bool { status == .ready }

    /// Lädt das Modell, falls nötig. Mehrere gleichzeitige Aufrufe teilen sich einen Ladevorgang.
    @discardableResult
    func ensureReady() async -> Bool {
        if status == .ready { return true }
        if let loadTask { return await loadTask.value }

        let model = modelName
        let isLocal = ModelStorage.localModelFolder(for: model) != nil
        status = isLocal ? .warmingUp : .downloading(0)
        errorDetails = nil
        if isLocal {
            // Dauert das Laden ungewöhnlich lange (z. B. erste Optimierung nach einem Update),
            // doch einen Hinweis zeigen.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(6))
                if self?.status == .warmingUp { self?.status = .loading }
            }
        }
        let task = Task { [engine] () -> Bool in
            do {
                try await engine.prepare(model: model) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.status != .ready, self.status != .warmingUp else { return }
                        if let progress {
                            self.status = .downloading(progress)
                        } else {
                            self.status = .loading
                        }
                    }
                }
                return true
            } catch {
                await MainActor.run { [weak self] in
                    self?.errorDetails = String(describing: error)
                }
                return false
            }
        }
        loadTask = task
        let ok = await task.value
        loadTask = nil
        status = ok ? .ready : .failed(Self.shortMessage(errorDetails))
        return ok
    }

    /// Nach einem Modellwechsel in den Einstellungen oder nach einem Fehler.
    func reload() {
        guard loadTask == nil else { return }
        status = .idle
        Task { await ensureReady() }
    }

    private static func shortMessage(_ details: String?) -> String {
        let text = (details ?? "").lowercased()
        if text.contains("offline") || text.contains("network") || text.contains("internet") || text.contains("timed out") {
            return String(localized: "Keine Internetverbindung für den Modell-Download.")
        }
        if text.contains("space") || text.contains("speicherplatz") {
            return String(localized: "Zu wenig Speicherplatz für das Sprachmodell.")
        }
        return String(localized: "Das Sprachmodell konnte nicht geladen werden.")
    }
}

extension WhisperModelOption {
    var shortLabel: String {
        switch self {
        case .base: return "Whisper Base"
        case .small: return "Whisper Small"
        case .largeTurbo: return "Whisper Large v3 Turbo"
        }
    }
}
