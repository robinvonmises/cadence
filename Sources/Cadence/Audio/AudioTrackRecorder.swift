import AVFoundation
import CadenceCore
import Foundation

/// Verarbeitet eine Audiospur (Mikrofon oder Systemaudio):
/// Eingangsformat → 48 kHz mono → M4A-Datei, und parallel → 16 kHz mono → Abschnittserkennung.
final class AudioTrackRecorder {
    let source: AudioSource
    private let queue: DispatchQueue
    private let storageFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    private let asrFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SpeechChunker.sampleRate, channels: 1, interleaved: false)!

    private var inputConverter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private lazy var asrConverter = AVAudioConverter(from: storageFormat, to: asrFormat)
    private var file: AVAudioFile?
    private var chunker: SpeechChunker
    private var writtenFrames: AVAudioFramePosition = 0
    private var lastError: Error?

    /// Wird auf der internen Queue aufgerufen.
    var onChunk: (@Sendable (SpeechChunk) -> Void)?
    /// Pegel 0…1, wird auf der internen Queue aufgerufen.
    var onLevel: (@Sendable (Float) -> Void)?
    /// 16-kHz-Mono-Audio für die Live-Erkennung, wird auf der internen Queue aufgerufen.
    var onSpeechBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    init(source: AudioSource, fileURL: URL?) throws {
        self.source = source
        self.queue = DispatchQueue(label: "cadence.track.\(source.rawValue)", qos: .userInitiated)
        self.chunker = SpeechChunker(source: source, configuration: .live)
        if let fileURL {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ]
            file = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
    }

    /// Aufgenommene Dauer in Sekunden.
    var recordedDuration: Double {
        queue.sync { Double(writtenFrames) / storageFormat.sampleRate }
    }

    /// Thread-sicher; darf aus Audio-Callbacks aufgerufen werden.
    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in self?.process(buffer) }
    }

    /// Restliche Daten verarbeiten und die Datei schließen.
    func finish() {
        queue.sync {
            if let chunk = chunker.flush() { onChunk?(chunk) }
            if #available(macOS 15.0, *) { file?.close() }
            file = nil
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        if inputFormat != buffer.format {
            inputFormat = buffer.format
            inputConverter = AVAudioConverter(from: buffer.format, to: storageFormat)
        }
        guard let converter = inputConverter, let mono48 = convert(buffer, with: converter, to: storageFormat) else { return }

        do {
            try file?.write(from: mono48)
        } catch {
            lastError = error
        }
        writtenFrames += AVAudioFramePosition(mono48.frameLength)

        guard let asrConverter, let mono16 = convert(mono48, with: asrConverter, to: asrFormat),
              let channel = mono16.floatChannelData?[0] else { return }
        onSpeechBuffer?(mono16)
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(mono16.frameLength)))
        for chunk in chunker.append(samples) { onChunk?(chunk) }
        onLevel?(min(1, SpeechChunker.rms(samples) * 6))
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var provided = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

enum AudioMixdown {
    /// Mischt Mikrofon- und Systemspur zu einer gemeinsamen M4A-Datei.
    static func combine(_ inputs: [URL], into output: URL) async throws {
        let composition = AVMutableComposition()
        for url in inputs where FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: .zero)
        }
        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "Cadence", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "Export nicht möglich")])
        }
        export.outputURL = output
        export.outputFileType = .m4a
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        if let error = export.error { throw error }
    }

    /// Lädt eine Audiodatei als 16 kHz mono Float-Array (für die Sprechertrennung).
    static func loadMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SpeechChunker.sampleRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return [] }
        var result: [Float] = []
        result.reserveCapacity(Int(Double(file.length) * target.sampleRate / file.processingFormat.sampleRate))
        let readSize: AVAudioFrameCount = 48_000
        var finished = false
        while !finished {
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: readSize) else { break }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { packets, outStatus in
                guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: packets),
                      (try? file.read(into: input, frameCount: packets)) != nil,
                      input.frameLength > 0 else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return input
            }
            if let error { throw error }
            if let data = output.floatChannelData?[0], output.frameLength > 0 {
                result.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
            }
            if status == .endOfStream || status == .error || output.frameLength == 0 { finished = true }
        }
        return result
    }
}
