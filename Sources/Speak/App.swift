import AppKit
import ApplicationServices
import AVFAudio
import Carbon.HIToolbox

@MainActor final class App: NSObject, NSApplicationDelegate {
    private let microphone = Microphone()
    private let hotkeys = Hotkeys()
    private lazy var settings = SettingsWindow { [microphone] in microphone.start() }
    private lazy var status = StatusItem { [unowned self] in settings.show() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        status.report("Loading model…")
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        Claude.prepare()
        Task {
            if await AVAudioApplication.requestRecordPermission() {
                microphone.start()
            } else {
                status.report("Microphone access denied")
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = Result { try Recognizer() }
            DispatchQueue.main.async { self.ready(loaded) }
        }
    }

    private func ready(_ loaded: Result<Recognizer, any Error>) {
        switch loaded {
        case .failure(let error):
            Log.error("\(error)")
            status.report("\(error)")
        case .success(let recognizer):
            let dictation = Dictation(ring: microphone.ring, recognizer: recognizer, status: status)
            hotkeys.register(kVK_F12) { dictation.hold(.type, pressed: $0) }
            hotkeys.register(kVK_F12, modifiers: shiftKey) { dictation.hold(.send, pressed: $0) }
            hotkeys.register(kVK_F11) { dictation.hold(.claude, pressed: $0) }
            status.report("Hold F12 to dictate")
            Log.debug("ready")
        }
    }
}
