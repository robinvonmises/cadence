import AudioToolbox
import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let message: String
    let status: OSStatus

    init(_ message: String, _ status: OSStatus) {
        self.message = message
        self.status = status
    }

    var errorDescription: String? { "\(message) (OSStatus \(status))" }
}

@discardableResult
func check(_ status: OSStatus, _ message: @autoclosure () -> String) throws -> OSStatus {
    guard status == noErr else { throw CoreAudioError(message(), status) }
    return status
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    private func address(_ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func read<T>(_ selector: AudioObjectPropertySelector, default value: T) throws -> T {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &result), "Eigenschaft \(selector) lesen")
        return result
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &value), "Text-Eigenschaft \(selector) lesen")
        guard let value else { throw CoreAudioError("Leerer Wert für \(selector)", -1) }
        return value.takeRetainedValue() as String
    }

    func readArray(_ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size), "Größe von \(selector) lesen")
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var list = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &list), "Liste \(selector) lesen")
        return list
    }

    static func defaultSystemOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice, default: AudioDeviceID(kAudioObjectUnknown))
    }

    func deviceUID() throws -> String {
        try readString(kAudioDevicePropertyDeviceUID)
    }

    func tapFormat() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
    }

    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID.system, &addr,
            UInt32(MemoryLayout<pid_t>.size), &pidValue,
            &size, &objectID
        )
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }
}
