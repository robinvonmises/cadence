import AppKit
import Carbon.HIToolbox

/// Systemweite Tastenkürzel (⌃⌥ + Taste), die auch funktionieren, während Teams im Vordergrund ist.
/// Nutzt `RegisterEventHotKey` – dafür ist keine Bedienungshilfen-Berechtigung nötig.
final class GlobalHotkeys {
    enum Action: Equatable {
        /// 1…9 = Person Nr. n in der Teilnehmerliste, 0 = „unbekannt“.
        case speaker(Int)
        case marker(MarkerKindShortcut)
        case focusSpeakerField
        case toggleRecording
    }

    enum MarkerKindShortcut: Equatable { case highlight, todo, decision }

    static let shared = GlobalHotkeys()

    /// Wird auf dem Main-Thread aufgerufen.
    var onAction: ((Action) -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var actions: [UInt32: Action] = [:]

    static let modifierSymbol = "⌃⌥"

    static let bindings: [(keyCode: Int, label: String, action: Action)] = {
        let digitKeys = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                         kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        var list: [(keyCode: Int, label: String, action: Action)] = digitKeys.enumerated().map {
            (keyCode: $0.element, label: "\($0.offset)", action: Action.speaker($0.offset))
        }
        list += [
            (keyCode: kVK_ANSI_M, label: "M", action: Action.marker(.highlight)),
            (keyCode: kVK_ANSI_A, label: "A", action: Action.marker(.todo)),
            (keyCode: kVK_ANSI_E, label: "E", action: Action.marker(.decision)),
            (keyCode: kVK_ANSI_N, label: "N", action: Action.focusSpeakerField),
            (keyCode: kVK_ANSI_R, label: "R", action: Action.toggleRecording)
        ]
        return list
    }()

    var isRegistered: Bool { handlerRef != nil }

    func register() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let hotkeys = Unmanaged<GlobalHotkeys>.fromOpaque(userData).takeUnretainedValue()
            hotkeys.fire(id: hotKeyID.id)
            return noErr
        }, 1, &eventType, selfPointer, &handlerRef)

        let modifiers = UInt32(controlKey | optionKey)
        let signature = OSType(0x43_44_4E_43) // "CDNC"
        for (index, binding) in Self.bindings.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(binding.keyCode), modifiers,
                EventHotKeyID(signature: signature, id: id),
                GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                refs.append(ref)
                actions[id] = binding.action
            }
        }
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

    private func fire(id: UInt32) {
        guard let action = actions[id] else { return }
        DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
    }
}
