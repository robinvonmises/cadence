import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Schneidet Systemaudio über einen Core Audio Process Tap mit (macOS 14.4+).
///
/// Vorteile gegenüber ScreenCaptureKit: keine Bildschirmaufnahme-Berechtigung nötig, nur
/// „Systemaudioaufnahme“; der Ton bleibt für dich unverändert hörbar; einzelne Apps lassen sich
/// gezielt abgreifen. Ablauf: Tap anlegen → privates Aggregate-Device mit dem Tap bauen →
/// IOProc liest die Samples.
final class SystemAudioTap {
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "cadence.systemaudio.io", qos: .userInitiated)
    private(set) var format: AVAudioFormat?
    private(set) var isRunning = false
    private let lastBuffer = Locked(Date())

    /// Sekunden seit dem letzten Audio-Zyklus. Ein Tap liefert auch bei Stille laufend Daten;
    /// bleibt er aus, ist das Gerät hängen geblieben (z. B. nach einem Bluetooth-Moduswechsel).
    var secondsSinceLastBuffer: Double {
        guard isRunning else { return 0 }
        return Date().timeIntervalSince(lastBuffer.withLock { $0 })
    }

    /// Taktgeber fürs Aggregate: die Standard-Ausgabe, außer sie ist Bluetooth oder AirPlay.
    /// Solche Geräte schlafen ein oder wechseln den Modus (z. B. durch die Echounterdrückung),
    /// dann bliebe der Tap stumm. In dem Fall lieber die eingebauten Lautsprecher nehmen.
    static func clockDevice() throws -> AudioDeviceID {
        let output = try AudioObjectID.defaultSystemOutputDevice()
        let unreliable: Set<UInt32> = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
                                        kAudioDeviceTransportTypeAirPlay]
        let transport = (try? output.read(kAudioDevicePropertyTransportType, default: UInt32(0))) ?? 0
        guard unreliable.contains(transport) else { return output }
        let devices = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices)) ?? []
        let builtIn = devices.first { id in
            (try? id.read(kAudioDevicePropertyTransportType, default: UInt32(0))) == kAudioDeviceTransportTypeBuiltIn
                && hasOutput(id)
        }
        return builtIn ?? output
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioObjectPropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    func start(target: SystemAudioTarget, handler: @escaping BufferHandler) throws {
        guard !isRunning else { return }

        // 1) Tap beschreiben
        let description: CATapDescription
        switch target {
        case .allSystemAudio:
            let exclude = AudioSourceCatalog.ownProcessObject().map { [$0] } ?? []
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        case .app(let bundleID, let name):
            let processes = AudioSourceCatalog.audioProcessObjects(forBundlePrefix: bundleID)
            guard !processes.isEmpty else {
                throw CoreAudioError(String(localized: "\(name) gibt gerade keinen Ton aus oder ist nicht gestartet. Tipp: „Gesamter Systemton“ funktioniert immer."), -1)
            }
            description = CATapDescription(stereoMixdownOfProcesses: processes)
        }
        description.uuid = UUID()
        description.name = "Cadence"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try check(AudioHardwareCreateProcessTap(description, &tapID), "Systemaudio-Tap anlegen")

        do {
            // 2) Aggregate-Device mit einem zuverlässigen Ausgabegerät als Taktgeber
            let outputUID = try Self.clockDevice().deviceUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Cadence System Audio",
                kAudioAggregateDeviceUIDKey: "de.cadence.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString
                ]]
            ]

            var streamDescription = try tapID.tapFormat()
            guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
                throw CoreAudioError("Unbekanntes Tap-Format", -1)
            }
            self.format = format

            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Aggregate-Device anlegen")

            // 3) IOProc: Buffer kopieren (die Originaldaten sind nur im Callback gültig)
            lastBuffer.withLock { $0 = Date() }
            let lastBuffer = self.lastBuffer
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, inInputData, _, _, _ in
                lastBuffer.withLock { $0 = Date() }
                guard let source = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil),
                      let copy = source.deepCopy() else { return }
                handler(copy)
            }, "IOProc anlegen")

            try check(AudioDeviceStart(aggregateID, procID), "Systemaudio starten")
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
    }

    deinit { stop() }
}

extension AVAudioPCMBuffer {
    /// Unabhängige Kopie, die den Callback überlebt.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sData = s.mData, let dData = d.mData else { continue }
            memcpy(dData, sData, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return copy
    }
}

/// Kleiner Thread-sicherer Wert für Audio-Callbacks.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
