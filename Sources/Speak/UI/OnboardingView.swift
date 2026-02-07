import SwiftUI
import AppKit
import AVFoundation

@Observable
class OnboardingState {
    enum Step: Int, CaseIterable {
        case microphone = 0
        case accessibility = 1
        case model = 2
        case preferences = 3
        case done = 4
    }

    var currentStep: Step = .microphone
    var micGranted = false
    var accessibilityGranted = false
    var hasModel = false
    var isDownloading = false
    var downloadProgress: Double = 0
    var downloadError: String?
    var selectedModelFilename = "ggml-large-v3-turbo-q5_0.bin"

    var hotkeyKeyCode: UInt16 = 0x6F
    var sendHotkeyKeyCode: UInt16 = 0x67
    var keepMicWarm: Bool = true
    var launchAtLogin: Bool = false

    private var pollTimer: Timer?
    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    func checkInitialState() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        hasModel = !findLocalModels().isEmpty

        if micGranted && accessibilityGranted && hasModel {
            currentStep = .done
        } else if micGranted && accessibilityGranted {
            currentStep = .model
        } else if micGranted {
            currentStep = .accessibility
        } else {
            currentStep = .microphone
        }
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.micGranted = granted
                if granted { self?.advanceFromPermissions() }
            }
        }
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        startPollingAccessibility()
    }

    func startPollingAccessibility() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            if AXIsProcessTrusted() {
                self?.accessibilityGranted = true
                self?.pollTimer?.invalidate()
                self?.pollTimer = nil
                self?.advanceFromPermissions()
            }
        }
    }

    func downloadModel() {
        let baseURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
        guard let url = URL(string: "\(baseURL)/\(selectedModelFilename)") else { return }

        isDownloading = true
        downloadProgress = 0
        downloadError = nil

        let dir = ModelManager.modelsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            DispatchQueue.main.async {
                self?.isDownloading = false
                if let error = error {
                    self?.downloadError = error.localizedDescription
                    return
                }
                guard let tempURL = tempURL else {
                    self?.downloadError = "Download failed"
                    return
                }
                let dest = dir.appendingPathComponent(self?.selectedModelFilename ?? "model.bin")
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    self?.hasModel = true
                    self?.currentStep = .preferences
                } catch {
                    self?.downloadError = error.localizedDescription
                }
            }
        }

        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.downloadProgress = progress.fractionCompleted
            }
        }

        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        isDownloading = false
        downloadProgress = 0
        progressObservation?.invalidate()
    }

    func finishPreferences() {
        var settings = WhisperSettings.load()
        settings.hotkeyKeyCode = hotkeyKeyCode
        settings.sendHotkeyKeyCode = sendHotkeyKeyCode
        settings.keepMicWarm = keepMicWarm
        settings.launchAtLogin = launchAtLogin
        settings.save()

        if launchAtLogin {
            LoginItemManager.setEnabled(true)
        }

        currentStep = .done
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        progressObservation?.invalidate()
    }

    var needsOnboarding: Bool {
        !micGranted || !accessibilityGranted || !hasModel
    }

    private func advanceFromPermissions() {
        if micGranted && accessibilityGranted {
            currentStep = hasModel ? .preferences : .model
        } else if micGranted {
            currentStep = .accessibility
        }
    }

    private func findLocalModels() -> [URL] {
        let fm = FileManager.default
        let dirs = [
            ModelManager.modelsDirectory,
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/models")
        ]
        var found: [URL] = []
        for dir in dirs {
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                found.append(contentsOf: files.filter { $0.pathExtension == "bin" })
            }
        }
        return found
    }

    static let availableModels: [(name: String, filename: String, size: String)] = [
        ("Large V3 Turbo Q5 (recommended)", "ggml-large-v3-turbo-q5_0.bin", "547 MB"),
        ("Large V3 Turbo", "ggml-large-v3-turbo.bin", "800 MB"),
        ("Medium English", "ggml-medium.en.bin", "1.5 GB"),
        ("Small English", "ggml-small.en.bin", "466 MB"),
        ("Base English", "ggml-base.en.bin", "142 MB"),
        ("Tiny English", "ggml-tiny.en.bin", "75 MB"),
    ]
}

struct OnboardingView: View {
    @Bindable var state: OnboardingState
    var onComplete: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Text("Welcome to Speak")
                .font(.title.bold())
                .padding(.top, 24)

            Text("Let's get you set up in a few steps.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .padding(.bottom, 20)

            stepIndicator
                .padding(.bottom, 16)

            Divider()

            Group {
                switch state.currentStep {
                case .microphone: microphoneStep
                case .accessibility: accessibilityStep
                case .model: modelStep
                case .preferences: preferencesStep
                case .done: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
        .frame(width: 460, height: 420)
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<4) { i in
                let isCurrent = state.currentStep.rawValue == i
                let isDone = state.currentStep.rawValue > i

                Circle()
                    .fill(isDone ? Color.green : (isCurrent ? Color.accentColor : Color.secondary.opacity(0.3)))
                    .frame(width: 8, height: 8)

                if i < 3 {
                    Rectangle()
                        .fill(isDone ? Color.green.opacity(0.5) : Color.secondary.opacity(0.15))
                        .frame(width: 40, height: 2)
                }
            }
        }
    }

    private var microphoneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)

            Text("Microphone Access")
                .font(.headline)

            Text("Speak needs your microphone to capture voice for transcription.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            if state.micGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Allow Microphone") {
                    state.requestMicrophone()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var accessibilityStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)

            Text("Accessibility Access")
                .font(.headline)

            Text("Required for the global hotkey (F12) and typing transcriptions into apps.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            if state.accessibilityGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                VStack(spacing: 8) {
                    Button("Open System Settings") {
                        state.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text("Find \"Speak\" in the list and enable it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Will detect automatically — no restart needed.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var modelStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)

            Text("Download a Model")
                .font(.headline)

            Text("Choose a whisper model for transcription. You can change this later.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Picker("Model", selection: $state.selectedModelFilename) {
                ForEach(OnboardingState.availableModels, id: \.filename) { model in
                    Text("\(model.name) — \(model.size)").tag(model.filename)
                }
            }
            .labelsHidden()

            Spacer()

            if state.isDownloading {
                VStack(spacing: 8) {
                    ProgressView(value: state.downloadProgress)
                    HStack {
                        Text("\(Int(state.downloadProgress * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                        Spacer()
                        Button("Cancel") { state.cancelDownload() }
                            .controlSize(.small)
                    }
                }
            } else {
                if let error = state.downloadError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button("Download") {
                    state.downloadModel()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var preferencesStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)

            Text("Quick Setup")
                .font(.headline)

            Form {
                HStack {
                    Text("Push-to-talk")
                    Spacer()
                    fkeyPicker(selection: $state.hotkeyKeyCode)
                }
                HStack {
                    Text("Talk + Send")
                    Spacer()
                    fkeyPicker(selection: $state.sendHotkeyKeyCode)
                }
                Toggle("Keep mic warm (instant start)", isOn: $state.keepMicWarm)
                    .focusable(false)
                Toggle("Launch at login", isOn: $state.launchAtLogin)
                    .focusable(false)
            }
            .formStyle(.grouped)

            Spacer()

            Button("Continue") {
                state.finishPreferences()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 50))
                .foregroundStyle(.green)

            Text("You're all set!")
                .font(.title2.bold())

            Text("Speak will restart to apply permissions.\nThen press F12 (or your chosen key) to start speaking.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            Button("Start Using Speak") {
                onComplete?()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func fkeyPicker(selection: Binding<UInt16>) -> some View {
        Picker("", selection: selection) {
            Text("F1").tag(UInt16(0x7A))
            Text("F2").tag(UInt16(0x78))
            Text("F3").tag(UInt16(0x63))
            Text("F4").tag(UInt16(0x76))
            Text("F5").tag(UInt16(0x60))
            Text("F6").tag(UInt16(0x61))
            Text("F7").tag(UInt16(0x62))
            Text("F8").tag(UInt16(0x64))
            Text("F9").tag(UInt16(0x65))
            Text("F10").tag(UInt16(0x6D))
            Text("F11").tag(UInt16(0x67))
            Text("F12").tag(UInt16(0x6F))
        }
        .frame(width: 100)
    }
}

class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?
    let state = OnboardingState()

    private var completionHandler: (() -> Void)?
    private var relaunchHandler: (() -> Void)?
    private var accessibilityWasGrantedDuringSession = false

    func showIfNeeded(onComplete: @escaping () -> Void, onRelaunchNeeded: @escaping () -> Void) {
        state.checkInitialState()
        accessibilityWasGrantedDuringSession = false

        if !state.accessibilityGranted {
            accessibilityWasGrantedDuringSession = true
        }

        guard state.needsOnboarding else {
            onComplete()
            return
        }

        completionHandler = onComplete
        relaunchHandler = onRelaunchNeeded
        show()
    }

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        state.checkInitialState()

        let view = OnboardingView(state: state, onComplete: { [weak self] in
            self?.state.stopPolling()
            self?.window?.close()
            self?.window = nil
            if self?.accessibilityWasGrantedDuringSession == true {
                self?.relaunchHandler?()
            } else {
                self?.completionHandler?()
            }
        })

        let hostingView = NSHostingView(rootView: view)
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Speak Setup"
        newWindow.contentView = hostingView
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.level = .floating
        newWindow.hidesOnDeactivate = false
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: newWindow, queue: .main) { [weak self] _ in
            self?.window = nil
        }

        window = newWindow
    }
}
