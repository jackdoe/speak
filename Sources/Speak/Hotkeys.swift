import Carbon.HIToolbox

@MainActor final class Hotkeys {
    private static let signature = "SPEK".utf8.reduce(OSType(0)) { $0 << 8 | OSType($1) }

    private var actions: [UInt32: (Bool) -> Void] = [:]

    init() {
        let kinds = [kEventHotKeyPressed, kEventHotKeyReleased].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
        }
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotkeys.actions[id.id]?(pressed) }
            return noErr
        }, kinds.count, kinds, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    func register(_ key: Int, modifiers: Int = 0, _ action: @escaping (Bool) -> Void) {
        let id = UInt32(actions.count + 1)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &reference)
        if status == noErr {
            actions[id] = action
        } else {
            Log.error("cannot register hotkey \(key) with modifiers \(modifiers): \(status)")
        }
    }
}
