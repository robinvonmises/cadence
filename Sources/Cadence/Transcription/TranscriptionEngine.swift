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

/// Speicherort der Modelle. Bewusst nicht ~/Documents: Liegt „Dokumente“ in iCloud Drive,
/// verschiebt oder entlädt macOS halb geladene Dateien, und der Download bricht ab.
enum ModelStorage {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Cadence/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Lokale Transkription mit WhisperKit. Ein Actor, damit Abschnitte beider Spuren nacheinander
/// abgearbeitet werden und das Modell nur einmal im Speicher liegt.
actor TranscriptionEngine {
    private var whisper: WhisperKit?
    private var loadedModel: String?

    var isReady: Bool { whisper != nil }

    /// Lädt das Modell herunter (falls nötig) und in den Speicher.
    /// - Parameter progress: 0…1 während des Downloads, `nil` beim Laden in die Neural Engine.
    func prepare(model: String, progress: @escaping @Sendable (Double?) -> Void) async throws {
        if loadedModel == model, whisper != nil { return }
        whisper = nil
        var lastError: Error?
        // Zwei Versuche: Abgebrochene Downloads werden beim zweiten Mal fortgesetzt.
        for _ in 0..<2 {
            do {
                let folder = try await WhisperKit.download(
                    variant: model,
                    downloadBase: ModelStorage.folder,
                    progressCallback: { p in progress(p.fractionCompleted) }
                )
                progress(nil)
                let config = WhisperKitConfig(
                    model: model,
                    modelFolder: folder.path,
                    verbose: false,
                    prewarm: true,
                    load: true,
                    download: false
                )
                whisper = try await WhisperKit(config)
                loadedModel = model
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CancellationError()
    }

    /// Transkribiert einen Abschnitt und liefert Segmente mit absoluten Zeiten.
    func transcribe(_ chunk: SpeechChunk, language: String?) async -> [TranscriptSegment] {
        guard let whisper else { return [] }

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

    /// Transkribiert eine komplette Audiodatei (z. B. wenn das Modell während der Aufnahme
    /// noch nicht bereit war).
    func transcribeFile(_ url: URL, source: AudioSource, language: String?,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> [TranscriptSegment] {
        let samples = try AudioMixdown.loadMono16k(url)
        var chunker = SpeechChunker(source: source)
        var chunks: [SpeechChunk] = []
        let step = Int(SpeechChunker.sampleRate) // 1 s
        var index = 0
        while index < samples.count {
            let end = min(index + step, samples.count)
            chunks += chunker.append(Array(samples[index..<end]))
            index = end
        }
        if let last = chunker.flush() { chunks.append(last) }
        var segments: [TranscriptSegment] = []
        for (n, chunk) in chunks.enumerated() {
            segments += await transcribe(chunk, language: language)
            progress(Double(n + 1) / Double(max(chunks.count, 1)))
        }
        return segments
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

/// Ergebnis der Sprechertrennung: wer wann spricht und ein Stimm-Fingerabdruck je Stimme.
struct DiarizationOutput: Sendable {
    var turns: [DiarizedTurn]
    var embeddings: [Int: [Float]]
}

/// Lokale Sprechertrennung mit SpeakerKit (pyannote, Core ML).
actor DiarizationEngine {
    private var speakerKit: SpeakerKit?

    func diarize(samples: [Float], expectedSpeakers: Int?) async throws -> DiarizationOutput {
        guard samples.count > Int(SpeechChunker.sampleRate * 2) else { return DiarizationOutput(turns: [], embeddings: [:]) }
        if speakerKit == nil {
            speakerKit = try await SpeakerKit(PyannoteConfig(downloadBase: ModelStorage.folder.path, load: true, verbose: false))
        }
        guard let speakerKit else { return DiarizationOutput(turns: [], embeddings: [:]) }
        let options = PyannoteDiarizationOptions(numberOfSpeakers: expectedSpeakers)
        let result = try await speakerKit.diarize(audioArray: samples, options: options)
        let turns: [DiarizedTurn] = result.segments.compactMap { segment in
            guard let id = segment.speaker.speakerId else { return nil }
            return DiarizedTurn(clusterID: id, start: Double(segment.startTime), end: Double(segment.endTime))
        }
        var embeddings: [Int: [Float]] = [:]
        for (cluster, embedding) in result.speakerCentroidEmbeddings {
            if let clean = VoiceMatcher.sanitized(embedding.map { Float($0) }) { embeddings[cluster] = clean }
        }
        return DiarizationOutput(turns: turns, embeddings: embeddings)
    }
}
