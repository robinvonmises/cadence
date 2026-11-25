import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown
    case protocolMarkdown
    case json
    case srt
    case plainText

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .markdown: return "Transkript (Markdown)"
        case .protocolMarkdown: return "Gesprächsprotokoll (Markdown)"
        case .json: return "Rohdaten (JSON)"
        case .srt: return "Untertitel (SRT)"
        case .plainText: return "Reiner Text"
        }
    }

    public var fileExtension: String {
        switch self {
        case .markdown, .protocolMarkdown: return "md"
        case .json: return "json"
        case .srt: return "srt"
        case .plainText: return "txt"
        }
    }

    public var defaultFileName: String {
        switch self {
        case .markdown: return "transkript.md"
        case .protocolMarkdown: return "protokoll.md"
        case .json: return "session.json"
        case .srt: return "untertitel.srt"
        case .plainText: return "transkript.txt"
        }
    }
}

public enum TimeFormat {
    /// 0:07, 12:34, 1:02:03
    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 00:01:02,345 (SRT)
    public static func srt(_ seconds: Double) -> String {
        let ms = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    public static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// Erzeugt alle Exportformate aus einer Session.
public struct SessionExporter {
    public var session: Session
    public var locale: Locale
    public var timeZone: TimeZone

    public init(session: Session, locale: Locale = Locale(identifier: "de_DE"), timeZone: TimeZone = .current) {
        self.session = session
        self.locale = locale
        self.timeZone = timeZone
    }

    public func export(_ format: ExportFormat) throws -> Data {
        switch format {
        case .markdown: return Data(markdown().utf8)
        case .protocolMarkdown: return Data(protocolMarkdown().utf8)
        case .json: return try Self.encoder.encode(session)
        case .srt: return Data(srt().utf8)
        case .plainText: return Data(plainText().utf8)
        }
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Hilfen

    private var dateString: String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = .full
        f.timeStyle = .short
        return f.string(from: session.startedAt)
    }

    /// Aufeinanderfolgende Abschnitte derselben Person zu Absätzen zusammenfassen.
    public func turns() -> [(name: String, partyName: String?, start: Double, end: Double, text: String)] {
        var result: [(name: String, partyName: String?, start: Double, end: Double, text: String)] = []
        for segment in session.sortedSegments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let name = session.displayName(for: segment)
            let partyName = session.party(of: session.person(segment.personID))?.name
            if var last = result.last, last.name == name, segment.start - last.end < 4 {
                last.text += " " + text
                last.end = segment.end
                result[result.count - 1] = last
            } else {
                result.append((name, partyName, segment.start, segment.end, text))
            }
        }
        return result
    }

    private func participantsSection() -> String {
        var lines: [String] = []
        for party in session.parties {
            let members = session.people(in: party).map(\.name)
            guard !members.isEmpty else { continue }
            lines.append("- **\(party.name):** \(members.joined(separator: ", "))")
        }
        let loose = session.peopleWithoutParty.map(\.name)
        if !loose.isEmpty { lines.append("- **Ohne Partei:** \(loose.joined(separator: ", "))") }
        let unmappedClusters = session.clusterIDs.filter { session.clusterAssignments[$0] == nil }
        if !unmappedClusters.isEmpty {
            lines.append("- **Nicht zugeordnet:** " + unmappedClusters.map { "Sprecher \($0 + 1)" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    private func markerLine(_ marker: Marker) -> String {
        "- `\(TimeFormat.clock(marker.time))` \(marker.kind.emoji) \(marker.text)"
    }

    // MARK: - Formate

    public func markdown() -> String {
        var out = "# \(session.title)\n\n"
        out += "_\(dateString) · Dauer \(TimeFormat.duration(session.duration))"
        if !session.sourceDescription.isEmpty { out += " · Quelle: \(session.sourceDescription)" }
        out += "_\n\n"
        out += "## Teilnehmer\n\n\(participantsSection())\n\n"
        if !session.markers.isEmpty {
            out += "## Marker & Notizen\n\n"
            out += session.markers.sorted { $0.time < $1.time }.map(markerLine).joined(separator: "\n")
            out += "\n\n"
        }
        out += "## Transkript\n\n"
        for turn in turns() {
            let party = turn.partyName.map { " (\($0))" } ?? ""
            out += "**\(turn.name)\(party)** `\(TimeFormat.clock(turn.start))`\n\(turn.text)\n\n"
        }
        return out
    }

    /// Protokoll-Vorlage: Kopf, Teilnehmer, Entscheidungen, Aufgaben, Notizen, Redeanteile, Verlauf.
    public func protocolMarkdown() -> String {
        let sortedMarkers = session.markers.sorted { $0.time < $1.time }
        func section(_ title: String, _ kinds: [MarkerKind], empty: String) -> String {
            let items = sortedMarkers.filter { kinds.contains($0.kind) }
            let body = items.isEmpty ? empty : items.map(markerLine).joined(separator: "\n")
            return "## \(title)\n\n\(body)\n\n"
        }

        var out = "# Gesprächsprotokoll: \(session.title)\n\n"
        out += "| | |\n|---|---|\n"
        out += "| **Datum** | \(dateString) |\n"
        out += "| **Dauer** | \(TimeFormat.duration(session.duration)) |\n"
        if !session.sourceDescription.isEmpty { out += "| **Quelle** | \(session.sourceDescription) |\n" }
        out += "| **Einwilligung zur Aufzeichnung** | \(session.consentConfirmed ? "bestätigt" : "nicht dokumentiert") |\n\n"
        out += "## Teilnehmer\n\n\(participantsSection())\n\n"
        out += section("Entscheidungen", [.decision], empty: "_Keine markiert._")
        out += section("Aufgaben", [.todo], empty: "_Keine markiert._")
        out += section("Wichtige Stellen & Notizen", [.highlight, .note], empty: "_Keine._")

        let speaking = session.speakingTime()
        let total = speaking.reduce(0) { $0 + $1.seconds }
        if total > 0 {
            out += "## Redeanteile\n\n"
            for entry in speaking {
                let percent = Int((entry.seconds / total * 100).rounded())
                out += "- \(entry.name): \(percent) % (\(TimeFormat.clock(entry.seconds)))\n"
            }
            out += "\n"
        }

        out += "## Gesprächsverlauf\n\n"
        for turn in turns() {
            out += "- `\(TimeFormat.clock(turn.start))` **\(turn.name):** \(turn.text)\n"
        }
        return out
    }

    public func srt() -> String {
        var out = ""
        for (index, segment) in session.sortedSegments.enumerated() {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out += "\(index + 1)\n\(TimeFormat.srt(segment.start)) --> \(TimeFormat.srt(segment.end))\n"
            out += "\(session.displayName(for: segment)): \(text)\n\n"
        }
        return out
    }

    public func plainText() -> String {
        turns().map { "[\(TimeFormat.clock($0.start))] \($0.name): \($0.text)" }.joined(separator: "\n")
    }
}
