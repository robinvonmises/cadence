import AudioToolbox
import CoreAudio
import Foundation

/// Ein Audio-Eingang (Mikrofon, Headset, Audio-Interface …).
struct InputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum InputDevices {
    /// Alle Geräte mit mindestens einem Eingangskanal, ohne Cadences eigene Hilfsgeräte.
    static func all() -> [InputDevice] {
        guard let ids = try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices) else { return [] }
        return ids.compactMap { id -> InputDevice? in
            guard hasInput(id),
                  let uid = try? id.deviceUID(),
                  !uid.hasPrefix("de.cadence."),
                  let name = try? id.readString(kAudioObjectPropertyName) else { return nil }
            return InputDevice(id: id, uid: uid, name: name)
        }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    static func defaultInput() -> AudioDeviceID? {
        try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultInputDevice, default: AudioDeviceID(kAudioObjectUnknown))
    }

    static func device(uid: String) -> AudioDeviceID? {
        all().first { $0.uid == uid }?.id
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }
}
