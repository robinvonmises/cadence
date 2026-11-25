import CadenceCore
import Foundation

/// Speichert jede Session in einem eigenen Ordner:
///
///     ~/Documents/Cadence/2026-11-25 1400 – Kickoff Kunde/
///         session.json      ← Rohdaten (Quelle der Wahrheit)
///         transkript.md     ← automatisch aktualisiert
///         protokoll.md
///         system.m4a        ← Gegenseite
///         mikrofon.m4a      ← du
///         gesamt.m4a        ← beide Spuren gemischt
@MainActor
final class SessionStore: ObservableObject {
    struct Entry: Identifiable, Hashable {
        let id: UUID
        let folder: URL
        var session: Session
    }

    @Published private(set) var entries: [Entry] = []
    /// Lernt bei jedem Speichern die zugeordneten Stimmen dazu.
    let voices: VoiceProfileStore

    init(voices: VoiceProfileStore) {
        self.voices = voices
    }

    static let sessionFileName = "session.json"

    var rootFolder: URL {
        if let custom = UserDefaults.standard.string(forKey: SettingsKey.storagePath), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Cadence", isDirectory: true)
    }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: rootFolder, withIntermediateDirectories: true)
        let folders = (try? fm.contentsOfDirectory(at: rootFolder, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Entry] = []
        for folder in folders where folder.hasDirectoryPath {
            let file = folder.appendingPathComponent(Self.sessionFileName)
            guard let data = try? Data(contentsOf: file),
                  let session = try? SessionExporter.decoder.decode(Session.self, from: data) else { continue }
            loaded.append(Entry(id: session.id, folder: folder, session: session))
        }
        entries = loaded.sorted { $0.session.startedAt > $1.session.startedAt }
    }

    func folder(for session: Session) -> URL {
        if let existing = entries.first(where: { $0.id == session.id }) { return existing.folder }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let safeTitle = session.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        let name = "\(formatter.string(from: session.startedAt)) – \(safeTitle.isEmpty ? "Gespräch" : safeTitle)"
        let folder = rootFolder.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Speichert session.json und die Markdown-Dateien.
    @discardableResult
    func save(_ session: Session, writeMarkdown: Bool = true) throws -> URL {
        let folder = folder(for: session)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let exporter = SessionExporter(session: session)
        try exporter.export(.json).write(to: folder.appendingPathComponent(Self.sessionFileName), options: .atomic)
        if writeMarkdown {
            try exporter.export(.markdown).write(to: folder.appendingPathComponent(ExportFormat.markdown.defaultFileName), options: .atomic)
            try exporter.export(.protocolMarkdown).write(to: folder.appendingPathComponent(ExportFormat.protocolMarkdown.defaultFileName), options: .atomic)
        }
        if let index = entries.firstIndex(where: { $0.id == session.id }) {
            entries[index].session = session
        } else {
            entries.insert(Entry(id: session.id, folder: folder, session: session), at: 0)
        }
        voices.learn(from: session)
        return folder
    }

    func audioURL(_ name: String?, in session: Session) -> URL? {
        guard let name else { return nil }
        let url = folder(for: session).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Verschiebt den Session-Ordner in den Papierkorb.
    func delete(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        try? FileManager.default.trashItem(at: entry.folder, resultingItemURL: nil)
        entries.removeAll { $0.id == id }
    }
}
