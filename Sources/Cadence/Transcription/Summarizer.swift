import CadenceCore
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Zusammenfassung, Entscheidungen und Aufgaben – lokal mit Apple Intelligence (Foundation Models).
/// Lange Gespräche werden in Stücken zusammengefasst und die Notizen danach zusammengeführt.
enum Summarizer {
    enum Failure: LocalizedError {
        case unavailable(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return reason
            case .empty: return String(localized: "Das Gespräch enthält noch keinen Text.")
            }
        }
    }

    /// `nil` = verfügbar, sonst ein Hinweis, warum nicht.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.appleIntelligenceNotEnabled):
                return String(localized: "Apple Intelligence ist ausgeschaltet. Du kannst es in den Systemeinstellungen unter „Apple Intelligence & Siri“ einschalten.")
            case .unavailable(.modelNotReady):
                return String(localized: "Das Apple-Intelligence-Modell wird noch geladen. Bitte versuche es später noch einmal.")
            case .unavailable(.deviceNotEligible):
                return String(localized: "Dieser Mac unterstützt Apple Intelligence nicht.")
            case .unavailable:
                return String(localized: "Apple Intelligence ist gerade nicht verfügbar.")
            }
        }
        return String(localized: "Zusammenfassungen brauchen macOS 26 mit Apple Intelligence.")
        #else
        return String(localized: "Diese Version von Cadence wurde ohne Apple Intelligence gebaut.")
        #endif
    }

    static var isAvailable: Bool { unavailableReason == nil }

    static func summarize(_ session: Session, status: @escaping @MainActor (String) -> Void) async throws -> MeetingSummary {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if let reason = unavailableReason { throw Failure.unavailable(reason) }
            return try await FoundationSummarizer.run(session, status: status)
        }
        #endif
        throw Failure.unavailable(unavailableReason ?? "")
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct GeneratedAction {
    @Guide(description: "Die Aufgabe als kurzer, konkreter Satz.")
    var task: String
    @Guide(description: "Name der verantwortlichen Person, wenn im Gespräch genannt, sonst leer.")
    var owner: String
}

@available(macOS 26.0, *)
@Generable
struct ChunkNotes {
    @Guide(description: "Die wichtigsten inhaltlichen Punkte dieses Abschnitts, je ein kurzer Satz.", .maximumCount(8))
    var keyPoints: [String]
    @Guide(description: "Ausdrücklich getroffene Entscheidungen. Leer, wenn keine.")
    var decisions: [String]
    @Guide(description: "Vereinbarte Aufgaben oder nächste Schritte. Leer, wenn keine.")
    var actionItems: [GeneratedAction]
}

@available(macOS 26.0, *)
@Generable
struct FinalSummary {
    @Guide(description: "Zusammenfassung des ganzen Gesprächs in 3 bis 5 Sätzen.")
    var overview: String
    @Guide(description: "Die wichtigsten Punkte, je ein kurzer Satz.", .maximumCount(8))
    var keyPoints: [String]
    @Guide(description: "Getroffene Entscheidungen, ohne Dopplungen.")
    var decisions: [String]
    @Guide(description: "Aufgaben und nächste Schritte, ohne Dopplungen.")
    var actionItems: [GeneratedAction]
}

@available(macOS 26.0, *)
private enum FoundationSummarizer {
    static let instructions = """
    Du fasst Besprechungsprotokolle sachlich zusammen. Das Transkript stammt aus einer automatischen \
    Spracherkennung und kann Fehler enthalten. Erfinde nichts, was nicht im Text steht. \
    Antworte in derselben Sprache wie das Transkript.
    """

    static func run(_ session: Session, status: @escaping @MainActor (String) -> Void) async throws -> MeetingSummary {
        let exporter = SessionExporter(session: session)
        var chunkSize = 5000
        var chunks = exporter.transcriptChunks(maxCharacters: chunkSize)
        guard !chunks.isEmpty else { throw Summarizer.Failure.empty }

        var notes: [ChunkNotes] = []
        var index = 0
        while index < chunks.count {
            await status(String(localized: "Zusammenfassung: Abschnitt \(index + 1) von \(chunks.count) …"))
            do {
                let model = LanguageModelSession(instructions: instructions)
                let response = try await model.respond(
                    to: "Notiere die wichtigsten Punkte, Entscheidungen und Aufgaben aus diesem Abschnitt eines Gesprächs:\n\n\(chunks[index])",
                    generating: ChunkNotes.self
                )
                notes.append(response.content)
                index += 1
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                // Zu lang für das Modell: kleinere Stücke versuchen.
                guard chunkSize > 1500 else { throw Summarizer.Failure.unavailable(String(localized: "Das Gespräch ist zu lang für die lokale Zusammenfassung.")) }
                chunkSize /= 2
                chunks = exporter.transcriptChunks(maxCharacters: chunkSize)
                notes = []
                index = 0
            }
        }

        await status(String(localized: "Zusammenfassung wird erstellt …"))
        var collected = notes.enumerated().map { offset, note in
            var text = "Abschnitt \(offset + 1):\n" + note.keyPoints.map { "- \($0)" }.joined(separator: "\n")
            if !note.decisions.isEmpty { text += "\nEntscheidungen:\n" + note.decisions.map { "- \($0)" }.joined(separator: "\n") }
            if !note.actionItems.isEmpty {
                text += "\nAufgaben:\n" + note.actionItems.map { "- \($0.task)" + ($0.owner.isEmpty ? "" : " (\($0.owner))") }.joined(separator: "\n")
            }
            return text
        }.joined(separator: "\n\n")
        if collected.count > 9000 { collected = String(collected.prefix(9000)) }

        let model = LanguageModelSession(instructions: instructions)
        let final = try await model.respond(
            to: "Titel des Gesprächs: \(session.title)\n\nHier sind Notizen zu den einzelnen Abschnitten. Fasse das ganze Gespräch zusammen und führe Entscheidungen und Aufgaben ohne Dopplungen zusammen:\n\n\(collected)",
            generating: FinalSummary.self
        ).content

        return MeetingSummary(
            overview: final.overview.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: final.keyPoints.filter { !$0.isEmpty },
            decisions: final.decisions.filter { !$0.isEmpty },
            actionItems: final.actionItems.filter { !$0.task.isEmpty }.map {
                ActionItem(text: $0.task, owner: $0.owner.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.owner)
            }
        )
    }
}
#endif
