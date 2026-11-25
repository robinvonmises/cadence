import CadenceCore
import Foundation
import SpeakerKit
import WhisperKit

/// Verfügbare Whisper-Modelle (werden beim ersten Start von Hugging Face geladen und lokal gecacht).
enum WhisperModelOption: String, CaseIterable, Identifiable {
    case base = "openai_whisper-base"
    case small = "openai_whisper-small"
    case largeTurbo = "openai_whisper-large-v3-v20240930_turbo"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .base: return "Base – sehr schnell, einfache Qualität (~150 MB)"
        case .small: return "Small – schnell, gute Qualität (~500 MB)"
        case .largeTurbo: return "Large v3 Turbo – beste Qualität, Apple Silicon empfohlen (~1,6 GB)"
        }
    }
}

/// Lokale Transkription mit WhisperKit. Ein Actor, damit Abschnitte beider Spuren nacheinander
/// abgearbeitet werden und das Modell nur einmal im Speicher liegt.
actor TranscriptionEngine {
    enum State: Equatable {
        case idle
        case loading(String)
        case ready
        case failed(String)
    }

    private var whisper: WhisperKit?
    private var loadedModel: String?
    private(set) var state: State = .idle
    private var pending = 0

    var backlog: Int { pending }

    func prepare(model: String) async throws {
        if loadedModel == model, whisper != nil { return }
        state = .loading(model)
        do {
            let config = WhisperKitConfig(model: model, verbose: false, prewarm: true, load: true, download: true)
            whisper = try await WhisperKit(config)
            loadedModel = model
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Transkribiert einen Abschnitt und liefert Segmente mit absoluten Zeiten.
    func transcribe(_ chunk: SpeechChunk, language: String?) async -> [TranscriptSegment] {
        guard let whisper else { return [] }
        pending += 1
        defer { pending -= 1 }

        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: language != nil,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            suppressBlank: true,
            noSpeechThreshold: 0.6
        )
        do {
            let results = try await whisper.transcribe(audioArray: chunk.samples, decodeOptions: options)
            var segments: [TranscriptSegment] = []
            for result in results {
                for segment in result.segments {
                    let text = Self.clean(segment.text)
                    guard !text.isEmpty, !Self.isHallucination(text), segment.noSpeechProb < 0.8 else { continue }
                    let start = chunk.startTime + Double(segment.start)
                    let end = min(chunk.startTime + Double(segment.end), chunk.startTime + chunk.duration)
                    segments.append(TranscriptSegment(source: chunk.source, start: start, end: max(end, start + 0.2), text: text))
                }
            }
            return segments
        } catch {
            return []
        }
    }

    /// Entfernt Whisper-Steuerzeichen wie <|de|> und überflüssige Leerzeichen.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Typische Whisper-Halluzinationen bei Stille oder Musik.
    static func isHallucination(_ text: String) -> Bool {
        let lower = text.lowercased()
        let patterns = [
            "untertitel im auftrag", "untertitel der amara", "vielen dank fürs zuschauen",
            "thank you for watching", "copyright", "swr 20", "zdf 20", "[musik]", "(musik)", "*musik*"
        ]
        return patterns.contains { lower.contains($0) } || lower.allSatisfy { !$0.isLetter }
    }
}

/// Lokale Sprechertrennung mit SpeakerKit (pyannote, Core ML).
actor DiarizationEngine {
    private var speakerKit: SpeakerKit?

    func diarize(samples: [Float], expectedSpeakers: Int?) async throws -> [DiarizedTurn] {
        guard samples.count > Int(SpeechChunker.sampleRate * 2) else { return [] }
        if speakerKit == nil {
            speakerKit = try await SpeakerKit(PyannoteConfig(modelDownloadConfig: nil, download: true, load: true, verbose: false))
        }
        guard let speakerKit else { return [] }
        let options = PyannoteDiarizationOptions(numberOfSpeakers: expectedSpeakers)
        let result = try await speakerKit.diarize(audioArray: samples, options: options)
        return result.segments.compactMap { segment in
            guard let id = segment.speaker.speakerId else { return nil }
            return DiarizedTurn(clusterID: id, start: Double(segment.startTime), end: Double(segment.endTime))
        }
    }
}
