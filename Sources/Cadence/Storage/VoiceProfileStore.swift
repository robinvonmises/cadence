import CadenceCore
import Foundation

/// Stimmprofile, lokal in ~/Library/Application Support/Cadence/stimmen.json.
/// Lernt aus jedem gespeicherten Gespräch, in dem Stimmen Personen zugeordnet sind.
@MainActor
final class VoiceProfileStore: ObservableObject {
    @Published private(set) var profiles: [VoiceProfile] = []

    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Cadence", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("stimmen.json")
        load()
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.voiceRecognition) }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? SessionExporter.decoder.decode([VoiceProfile].self, from: data) else { return }
        profiles = decoded
    }

    private func persist() {
        guard let data = try? SessionExporter.encoder.encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Stimmen eines (fertigen) Gesprächs übernehmen.
    func learn(from session: Session) {
        guard isEnabled, session.state == .finished, session.clusterEmbeddings != nil else { return }
        var updated = profiles
        updated.learn(from: session)
        guard updated != profiles else { return }
        profiles = updated
        persist()
    }

    /// Bekannte Stimmen in einem frisch getrennten Gespräch eintragen.
    @discardableResult
    func recognize(in session: inout Session) -> [String] {
        guard isEnabled, let embeddings = session.clusterEmbeddings, !profiles.isEmpty else { return [] }
        let open = embeddings.filter { session.clusterAssignments[$0.key] == nil }
        let matches = VoiceMatcher.match(clusters: open, profiles: profiles)
        return session.applyRecognizedVoices(matches, profiles: profiles)
    }

    func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        persist()
    }

    func deleteAll() {
        profiles = []
        persist()
    }
}
