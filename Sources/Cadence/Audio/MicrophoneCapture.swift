import AVFoundation
import AudioToolbox
import Foundation

/// Nimmt das eigene Mikrofon als separate Spur auf.
final class MicrophoneCapture {
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void

    private let engine = AVAudioEngine()
    private(set) var isRunning = false

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// - Parameter voiceProcessing: Apples Echounterdrückung. Hilfreich ohne Kopfhörer, damit die
    ///   Stimmen der Gegenseite aus den Lautsprechern nicht zusätzlich als „du“ transkribiert werden.
    /// - Parameter deviceUID: bestimmtes Eingangsgerät; `nil` = Systemstandard.
    func start(voiceProcessing: Bool, deviceUID: String? = nil, handler: @escaping BufferHandler) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        if let deviceUID, var deviceID = InputDevices.device(uid: deviceUID), let unit = input.audioUnit {
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)),
                      String(localized: "Mikrofon auswählen"))
        }
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            // Andere Apps (Teams!) nicht leiser drehen.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Cadence", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Kein Mikrofon gefunden.")])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            handler(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if engine.inputNode.isVoiceProcessingEnabled {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        isRunning = false
    }
}
