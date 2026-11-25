import Foundation

/// Ein fertiger Audioabschnitt (16 kHz mono), bereit für die Transkription.
public struct SpeechChunk: Sendable {
    public var source: AudioSource
    /// Startzeit in Sekunden seit Aufnahmebeginn.
    public var startTime: Double
    public var samples: [Float]

    public var duration: Double { Double(samples.count) / SpeechChunker.sampleRate }
}

/// Zerlegt einen kontinuierlichen 16-kHz-Strom in sprachnahe Abschnitte.
///
/// Einfache, robuste Energie-VAD: Ein Abschnitt wird abgeschlossen, sobald nach Sprache eine
/// kurze Pause kommt (natürliche Satzgrenze) oder eine Maximallänge erreicht ist. Reine Stille
/// wird verworfen, damit Whisper keine Fantasietexte („Vielen Dank fürs Zuschauen“) erzeugt.
public struct SpeechChunker: Sendable {
    public static let sampleRate: Double = 16_000

    public struct Configuration: Sendable {
        /// Länge eines Analysefensters.
        public var frameDuration: Double = 0.03
        /// Pause, nach der ein Abschnitt abgeschlossen wird.
        public var silenceToCut: Double = 0.7
        public var minChunkDuration: Double = 1.2
        public var maxChunkDuration: Double = 25
        /// Mindestanteil an „Sprach“-Fenstern, damit ein Abschnitt überhaupt transkribiert wird.
        public var minVoicedRatio: Double = 0.08
        /// Absolute Untergrenze für den RMS-Pegel, ab dem ein Fenster als Sprache gilt.
        public var minThreshold: Float = 0.004
        /// Faktor über dem geschätzten Grundrauschen.
        public var noiseFactor: Float = 3.0

        public init() {}
    }

    public let source: AudioSource
    public var configuration: Configuration

    private var buffer: [Float] = []
    private var bufferStartSample: Int = 0
    private var totalSamples: Int = 0
    private var pending: [Float] = []
    private var voicedFrames = 0
    private var frames = 0
    private var trailingSilentFrames = 0
    private var hasSpeech = false
    private var noiseFloor: Float = 0.002

    public init(source: AudioSource, configuration: Configuration = Configuration()) {
        self.source = source
        self.configuration = configuration
    }

    private var frameLength: Int { Int(configuration.frameDuration * Self.sampleRate) }

    /// Aktueller Pegel (RMS des letzten Fensters) – für die Pegelanzeige.
    public private(set) var lastLevel: Float = 0

    /// Neue Samples anhängen. Gibt abgeschlossene Abschnitte zurück.
    public mutating func append(_ samples: [Float]) -> [SpeechChunk] {
        var output: [SpeechChunk] = []
        pending.append(contentsOf: samples)
        let length = frameLength
        var offset = 0
        while pending.count - offset >= length {
            let frame = Array(pending[offset..<(offset + length)])
            offset += length
            if let chunk = process(frame: frame) { output.append(chunk) }
        }
        pending.removeFirst(offset)
        return output
    }

    /// Restpuffer als letzten Abschnitt ausgeben (beim Stoppen).
    public mutating func flush() -> SpeechChunk? {
        if !pending.isEmpty {
            if buffer.isEmpty { bufferStartSample = totalSamples }
            buffer.append(contentsOf: pending)
            totalSamples += pending.count
            pending.removeAll()
        }
        return cut(force: true)
    }

    private mutating func process(frame: [Float]) -> SpeechChunk? {
        if buffer.isEmpty { bufferStartSample = totalSamples }
        buffer.append(contentsOf: frame)
        totalSamples += frame.count
        frames += 1

        let level = Self.rms(frame)
        lastLevel = level
        let threshold = max(configuration.minThreshold, noiseFloor * configuration.noiseFactor)
        let voiced = level > threshold
        if voiced {
            voicedFrames += 1
            trailingSilentFrames = 0
            hasSpeech = true
        } else {
            trailingSilentFrames += 1
            // Grundrauschen langsam an ruhige Fenster anpassen.
            noiseFloor = noiseFloor * 0.98 + level * 0.02
        }

        let duration = Double(buffer.count) / Self.sampleRate
        let silence = Double(trailingSilentFrames) * configuration.frameDuration

        if !hasSpeech {
            // Reine Stille nicht endlos ansammeln: nur ein kurzes Vorlauf-Polster behalten.
            let keep = Int(0.3 * Self.sampleRate)
            if buffer.count > keep * 2 {
                let drop = buffer.count - keep
                buffer.removeFirst(drop)
                bufferStartSample += drop
                frames = 0
                voicedFrames = 0
            }
            return nil
        }

        if duration >= configuration.maxChunkDuration { return cut(force: true) }
        if silence >= configuration.silenceToCut && duration >= configuration.minChunkDuration {
            return cut(force: false)
        }
        return nil
    }

    private mutating func cut(force: Bool) -> SpeechChunk? {
        defer {
            buffer.removeAll(keepingCapacity: true)
            frames = 0
            voicedFrames = 0
            trailingSilentFrames = 0
            hasSpeech = false
        }
        guard !buffer.isEmpty, hasSpeech else { return nil }
        let ratio = frames > 0 ? Double(voicedFrames) / Double(frames) : 0
        guard ratio >= configuration.minVoicedRatio else { return nil }
        guard Double(buffer.count) / Self.sampleRate >= 0.5 else { return nil }
        return SpeechChunk(
            source: source,
            startTime: Double(bufferStartSample) / Self.sampleRate,
            samples: buffer
        )
    }

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
