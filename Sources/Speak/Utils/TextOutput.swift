import AppKit
import CoreGraphics

class TextOutput {

    static func type(_ text: String, delayMs: Int = 1) {
        guard !text.isEmpty else { return }

        let source = CGEventSource(stateID: .privateState)
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents, .permitLocalKeyboardEvents],
                                                           state: .eventSuppressionStateSuppressionInterval)

        let delayUs = UInt32(max(1000, delayMs * 1000))

        for char in text {
            let str = String(char)
            let utf16 = Array(str.utf16)

            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x31, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x31, keyDown: false) else {
                continue
            }

            keyDown.flags = []
            keyUp.flags = []

            keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)

            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)

            usleep(delayUs)
        }
    }

    static func pressReturn() {
        usleep(50_000)
        let source = CGEventSource(stateID: .privateState)
        let returnKeyCode: UInt16 = 0x24
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: true) {
            keyDown.flags = []
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        usleep(5000)
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: returnKeyCode, keyDown: false) {
            keyUp.flags = []
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    static func paste(_ text: String, restoreClipboard: Bool = true) {
        let pasteboard = NSPasteboard.general
        let previousString = restoreClipboard ? pasteboard.string(forType: .string) : nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .privateState)
        let vKeyCode: UInt16 = 9

        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        usleep(5000)
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }

        if restoreClipboard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                pasteboard.clearContents()
                if let prev = previousString {
                    pasteboard.setString(prev, forType: .string)
                }
            }
        }
    }
}
