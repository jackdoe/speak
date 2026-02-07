import SwiftUI
import AppKit
import AVFoundation

@main
struct SpeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    let statusBarController = StatusBarController()
    let hotkeyManager = HotkeyManager()
    let pipeline = TranscriptionPipeline()

    static func relaunch() {
        let path = ProcessInfo.processInfo.arguments[0]
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = []
        task.environment = ProcessInfo.processInfo.environment
        try? task.run()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.stop()
        pipeline.audioEngine.releaseEngine()
        pipeline.shutdown()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController.setup()
        wireCallbacks()

        OnboardingWindowController.shared.showIfNeeded(
            onComplete: { [weak self] in self?.startApp() },
            onRelaunchNeeded: { Self.relaunch() }
        )
    }

    private func wireCallbacks() {
        hotkeyManager.onKeyDown = { [weak self] isSend in
            self?.handleKeyDown()
        }
        hotkeyManager.onKeyUp = { [weak self] isSend in
            self?.handleKeyUp(sendReturn: isSend)
        }

        statusBarController.onModelSelected = { [weak self] modelName in
            self?.selectModel(named: modelName)
        }
        statusBarController.onSettingsClicked = { [weak self] in
            self?.openSettings(tab: nil)
        }
        statusBarController.onDownloadMoreClicked = { [weak self] in
            self?.openSettings(tab: 0)
        }
        statusBarController.onSetupClicked = {
            OnboardingWindowController.shared.show()
        }
        statusBarController.isMicWarm = pipeline.settings.keepMicWarm
        statusBarController.onMicWarmToggled = { [weak self] enabled in
            guard let self = self else { return }
            self.pipeline.settings.keepMicWarm = enabled
            self.pipeline.settings.save()
            if enabled {
                do { try self.pipeline.audioEngine.prepare() } catch {
                    NSLog("[SpeakApp] Failed to warm mic: %@", error.localizedDescription)
                }
            } else {
                self.pipeline.audioEngine.releaseEngine()
            }
        }
    }

    private func startApp() {
        pipeline.settings = WhisperSettings.load()
        pipeline.applyVADSettings()

        hotkeyManager.setKeyCodes(
            primary: pipeline.settings.hotkeyKeyCode,
            send: pipeline.settings.sendHotkeyKeyCode
        )
        if !hotkeyManager.start() {
            NSLog("[SpeakApp] Hotkey manager failed to start")
        }

        statusBarController.isMicWarm = pipeline.settings.keepMicWarm
        if pipeline.settings.keepMicWarm {
            do { try pipeline.audioEngine.prepare() } catch {
                NSLog("[SpeakApp] Failed to pre-warm audio: %@", error.localizedDescription)
            }
        }

        pipeline.modelManager.scanForModels()
        refreshModelList()

        if pipeline.modelManager.availableModels.isEmpty {
            NSLog("[SpeakApp] No models found — opening download page")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openSettings(tab: 0)
            }
        } else {
            Task {
                do {
                    try await pipeline.loadFirstAvailableModel()
                    refreshModelList()
                    NSLog("[SpeakApp] Auto-loaded model")
                } catch {
                    NSLog("[SpeakApp] No model auto-loaded: %@", error.localizedDescription)
                }
            }
        }

        NSLog("[SpeakApp] Launch complete")
    }

    private func handleKeyDown() {
        let t0 = CFAbsoluteTimeGetCurrent()
        pipeline.startRecording()
        let t1 = CFAbsoluteTimeGetCurrent()
        statusBarController.state = .recording
        let t2 = CFAbsoluteTimeGetCurrent()

        if pipeline.settings.showOverlay {
            RecordingOverlayController.shared.show(
                position: pipeline.settings.overlayPosition,
                audioEngine: pipeline.audioEngine
            )
        }
        let t3 = CFAbsoluteTimeGetCurrent()
        NSLog("[Timing] F12 down → startRecording: %.1fms, statusBar: %.1fms, overlay: %.1fms, total: %.1fms",
              (t1-t0)*1000, (t2-t1)*1000, (t3-t2)*1000, (t3-t0)*1000)
    }

    private func handleKeyUp(sendReturn: Bool = false) {
        let t0 = CFAbsoluteTimeGetCurrent()
        statusBarController.state = .transcribing
        RecordingOverlayController.shared.setTranscribing()

        Task {
            let t1 = CFAbsoluteTimeGetCurrent()
            let result = await pipeline.stopRecordingAndTranscribe()
            let t2 = CFAbsoluteTimeGetCurrent()
            await MainActor.run {
                if sendReturn, let result = result, !result.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        TextOutput.pressReturn()
                    }
                }
                statusBarController.state = .idle
                RecordingOverlayController.shared.hide()
                let t3 = CFAbsoluteTimeGetCurrent()
                NSLog("[Timing] key up → stopAudio+transcribe: %.1fms, cleanup: %.1fms, total: %.1fms%@",
                      (t2-t1)*1000, (t3-t2)*1000, (t3-t0)*1000, sendReturn ? " [+Return]" : "")
            }
        }
    }

    private func refreshModelList() {
        let modelNames = pipeline.modelManager.availableModels.map { $0.name }
        let currentName = pipeline.modelManager.currentModel?.name
        statusBarController.updateModelsSubmenu(models: modelNames, current: currentName)
    }

    func openSettings(tab: Int? = nil) {
        let modelName = pipeline.modelManager.currentModel?.name ?? ""
        let modelPath = pipeline.modelManager.currentModel?.path ?? ""
        SettingsWindowController.shared.showSettings(
            settings: pipeline.settings,
            vad: pipeline.audioEngine.voiceActivityDetector,
            modelName: modelName,
            modelPath: modelPath,
            localModels: pipeline.modelManager.availableModels,
            initialTab: tab,
            onChanged: { [weak self] newSettings in
                self?.pipeline.settings = newSettings
                self?.hotkeyManager.setKeyCodes(primary: newSettings.hotkeyKeyCode, send: newSettings.sendHotkeyKeyCode)
                self?.statusBarController.isMicWarm = newSettings.keepMicWarm
            },
            onModelDownloaded: { [weak self] in
                guard let self = self else { return }
                let hadNoModels = self.pipeline.modelManager.currentModel == nil
                self.pipeline.modelManager.scanForModels()
                self.refreshModelList()

                if hadNoModels {
                    Task {
                        do {
                            try await self.pipeline.loadFirstAvailableModel()
                            await MainActor.run { self.refreshModelList() }
                            NSLog("[SpeakApp] Auto-loaded first downloaded model")
                        } catch {
                            NSLog("[SpeakApp] Failed to auto-load: %@", error.localizedDescription)
                        }
                    }
                }

                SettingsWindowController.shared.closeAndReopen()
                self.openSettings(tab: 0)
            }
        )
    }

    private func selectModel(named name: String) {
        guard let model = pipeline.modelManager.availableModels.first(where: { $0.name == name }) else {
            return
        }
        Task {
            do {
                try await pipeline.loadModel(model)
                await MainActor.run { refreshModelList() }
                NSLog("[SpeakApp] Loaded model: %@", model.name)
            } catch {
                NSLog("[SpeakApp] Failed to load model: %@", error.localizedDescription)
            }
        }
    }

}
