import Carbon.HIToolbox
import CoreGraphics

enum Keyboard {
    private static let unitsPerEvent = 20

    static func type(_ text: String) {
        var units: [UniChar] = []
        for character in text {
            let next = Array(character.utf16)
            if units.count + next.count > unitsPerEvent {
                press(kVK_Space, units)
                units = []
            }
            units += next
        }
        if !units.isEmpty { press(kVK_Space, units) }
    }

    static func pressReturn() {
        press(kVK_Return, [])
    }

    private static func press(_ key: Int, _ units: [UniChar]) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down) else { continue }
            event.flags = []
            if !units.isEmpty { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units) }
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
