import AVFoundation
import CadenceCore
import Foundation
#if canImport(FoundationModels)
// FoundationModels gibt es nur im macOS-26-SDK – dort steckt auch der neue SpeechAnalyzer.
import Speech
#endif

/// Live-Text Wort für Wort mit Apples Spracherkennung (macOS 26, lokal auf dem Mac).
/// Whisper schreibt nach dem Gespräch die saubere Endfassung; dies hier ist nur für die Live-Ansicht.
final class LiveSpeech: @unchecked Sendable {
    typealias Partial = @Sendable (_ text: String, _ start: Double) -> Void
    typealias Final = @Sendable (_ text: String, _ start: Double, _ end: Double) -> Void

    private let lock = NSLock()
    private var feed: ((AVAudioPCMBuffer) -> Void)?
    private var finishHandler: (() async -> Void)?
    /// Audio, das ankommt, bevor die Erkennung bereit ist (z. B. während das Sprachpaket lädt).
    private var pending: [AVAudioPCMBuffer] = []
    private var stopped = false

    /// Unterstützt dieser Mac Live-Text in dieser Sprache? (`nil` = automatische Spracherkennung → nein)
    static func isSupported(languageCode: String?) async -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let languageCode {
            return await AppleSpeech.locale(for: languageCode) != nil
        }
        #endif
        return false
    }

    /// Startet die Erkennung. Audio, das schon vorher über `append` kommt, wird nachgeholt.
    func start(languageCode: String, onPartial: @escaping Partial, onFinal: @escaping Final) async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let speech = AppleSpeech()
            try await speech.start(languageCode: languageCode, onPartial: onPartial, onFinal: onFinal)
            let backlog = lock.withLock { () -> [AVAudioPCMBuffer] in
                feed = { speech.append($0) }
                finishHandler = { await speech.finish() }
                defer { pending = [] }
                return pending
            }
            for buffer in backlog { speech.append(buffer) }
            return
        }
        #endif
        throw CancellationError()
    }

    /// 16-kHz-Mono-Puffer aus der Spur. Thread-sicher.
    func append(_ buffer: AVAudioPCMBuffer) {
        let feed = lock.withLock { () -> ((AVAudioPCMBuffer) -> Void)? in
            if self.feed == nil, !stopped, pending.count < 20_000 { pending.append(buffer) }
            return self.feed
        }
        feed?(buffer)
    }

    /// Restliches Audio verarbeiten und beenden.
    func finish() async {
        let handler = lock.withLock { () -> (() async -> Void)? in
            let h = finishHandler
            finishHandler = nil
            feed = nil
            stopped = true
            pending = []
            return h
        }
        await handler?()
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
private final class AppleSpeech: @unchecked Sendable {
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?
    private let lock = NSLock()

    static func locale(for languageCode: String) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: languageCode))
    }

    func start(languageCode: String, onPartial: @escaping LiveSpeech.Partial, onFinal: @escaping LiveSpeech.Final) async throws {
        guard let locale = await Self.locale(for: languageCode) else { throw CancellationError() }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        // Sprachmodell einmalig vom System laden lassen (falls noch nicht vorhanden).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw CancellationError()
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        lock.withLock {
            self.format = format
            self.input = continuation
            self.analyzer = analyzer
        }

        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    let start = result.range.start.seconds.isFinite ? result.range.start.seconds : 0
                    let end = result.range.end.seconds.isFinite ? result.range.end.seconds : start
                    if result.isFinal {
                        if !text.isEmpty { onFinal(text, start, max(end, start + 0.2)) }
                        onPartial("", end)
                    } else {
                        onPartial(text, start)
                    }
                }
            } catch {
                onPartial("", 0)
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let input, let format else { return }
        if buffer.format == format {
            input.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var provided = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if provided { status.pointee = .noDataNow; return nil }
            provided = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, output.frameLength > 0 { input.yield(AnalyzerInput(buffer: output)) }
    }

    func finish() async {
        let (input, analyzer) = lock.withLock { () -> (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?) in
            let pair = (self.input, self.analyzer)
            self.input = nil
            return pair
        }
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
    }
}
#endif
