import SwiftUI
import AppKit

struct SettingsView: View {
    @State var settings: WhisperSettings
    @Bindable var vad: VoiceActivityDetector
    var currentModelName: String
    var currentModelPath: String
    var onSettingsChanged: ((WhisperSettings) -> Void)?
    var onModelDownloaded: (() -> Void)?
    @State private var downloader = ModelDownloader()
    var localModels: [WhisperModel] = []
    var initialTab: Int? = nil

    @State private var selectedTab: Int = 1
    @FocusState private var promptFieldFocused: Bool

    private let tabs = ["Models", "General", "VAD", "Advanced"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, title in
                    tabButton(title: title, index: index)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                switch selectedTab {
                case 0: modelsTab
                case 1: generalTab
                case 2: vadTab
                case 3: advancedTab
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 540, height: 560)
        .onAppear {
            if let tab = initialTab {
                selectedTab = tab
            } else {
                selectedTab = localModels.isEmpty ? 0 : 1
            }
        }
        .onChange(of: settings) { _, newValue in
            newValue.save()
            onSettingsChanged?(newValue)
        }
    }

    private func tabButton(title: String, index: Int) -> some View {
        Button(action: { selectedTab = index }) {
            Text(title)
                .font(.system(size: 12, weight: selectedTab == index ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selectedTab == index ? Color.accentColor.opacity(0.15) : Color.clear)
                .foregroundStyle(selectedTab == index ? .primary : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
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
            Text("F13").tag(UInt16(0x69))
            Text("F14").tag(UInt16(0x6B))
            Text("F15").tag(UInt16(0x71))
        }
        .frame(width: 100)
    }

    private var modelsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            installedModelsSection

            Divider()
                .padding(.vertical, 4)

            remoteModelsSection
        }
        .onAppear { refreshModels() }
    }

    private var installedModelsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Installed Models")
                    .font(.headline)
                Spacer()
                Text(ModelManager.modelsDirectory.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if localModels.isEmpty {
                Text("No models installed. Download one below.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            } else {
                ForEach(localModels) { model in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name)
                                .fontWeight(currentModelName == model.name ? .semibold : .regular)
                            Text(model.sizeDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if currentModelName == model.name {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var remoteModelsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download from HuggingFace")
                        .font(.headline)
                    Text("huggingface.co/ggerganov/whisper.cpp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: { refreshModels() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(downloader.isRefreshing)
                .focusable(false)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 8)

            if downloader.isRefreshing {
                HStack {
                    Spacer()
                    ProgressView("Fetching model list...")
                    Spacer()
                }
                .padding()
            }

            if let error = downloader.error {
                Text("Error: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            List(downloader.remoteModels) { model in
                modelRow(model)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func modelRow(_ model: RemoteModel) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .fontWeight(model.isDownloaded ? .semibold : .regular)
                Text(model.sizeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let progress = downloader.downloadProgress[model.filename], progress < 1.0 {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: progress)
                        .frame(width: 100)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button(action: { downloader.cancelDownload(model.filename) }) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .focusable(false)
            } else if let error = downloader.downloadErrors[model.filename] {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .frame(maxWidth: 120)
                Button("Retry") { startDownload(model) }
                    .controlSize(.small)
                    .focusable(false)
            } else if model.isDownloaded {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("Download") { startDownload(model) }
                    .controlSize(.small)
                    .focusable(false)
            }
        }
        .padding(.vertical, 2)
    }

    private func refreshModels() {
        Task {
            await downloader.refreshModelList(localModels: localModels)
        }
    }

    private func startDownload(_ model: RemoteModel) {
        downloader.download(model) { result in
            switch result {
            case .success:
                onModelDownloaded?()
            case .failure(let error):
                NSLog("[Settings] Download failed: %@", error.localizedDescription)
            }
        }
    }

    private var generalTab: some View {
        ScrollView {
            Form {
                if !AXIsProcessTrusted() {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Accessibility not enabled")
                                    .fontWeight(.medium)
                                Text("Hotkeys and text output won't work. Open System Settings > Privacy & Security > Accessibility, remove Speak if listed, then re-add it and restart the app.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Open Accessibility Settings") {
                            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                            NSWorkspace.shared.open(url)
                        }
                        .focusable(false)
                    }
                }

                Section("Language") {
                    Picker("Language", selection: $settings.language) {
                        Text("Auto-detect").tag("auto")
                        Divider()
                        Text("English").tag("en")
                        Text("Chinese").tag("zh")
                        Text("German").tag("de")
                        Text("Spanish").tag("es")
                        Text("French").tag("fr")
                        Text("Italian").tag("it")
                        Text("Japanese").tag("ja")
                        Text("Korean").tag("ko")
                        Text("Portuguese").tag("pt")
                        Text("Russian").tag("ru")
                        Text("Dutch").tag("nl")
                        Text("Polish").tag("pl")
                        Text("Turkish").tag("tr")
                        Text("Ukrainian").tag("uk")
                        Text("Arabic").tag("ar")
                        Text("Hindi").tag("hi")
                    }
                    Toggle("Translate to English", isOn: $settings.translate)
                        .focusable(false)
                }

                Section("Hotkeys") {
                    HStack {
                        Text("Push-to-talk")
                        Spacer()
                        fkeyPicker(selection: $settings.hotkeyKeyCode)
                    }
                    HStack {
                        Text("Talk + Send (Return)")
                        Spacer()
                        fkeyPicker(selection: $settings.sendHotkeyKeyCode)
                    }
                    Toggle("Keep mic warm (instant start)", isOn: $settings.keepMicWarm)
                        .focusable(false)
                }

                Section("Transcription Mode") {
                    Picker("Mode", selection: $settings.transcriptionMode) {
                        ForEach(WhisperSettings.TranscriptionMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    Text("Continuous outputs text each time you pause speaking")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Stepper(
                        "Release delay: \(settings.releaseDelayMs) ms",
                        value: $settings.releaseDelayMs,
                        in: 0...1000,
                        step: 50
                    )
                    .focusable(false)
                    Text("Extra recording time after key release to avoid clipping")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Section("Output Mode") {
                    Picker("Mode", selection: $settings.outputMode) {
                        ForEach(WhisperSettings.OutputMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    if settings.outputMode == .type {
                        Stepper(
                            "Typing speed: \(settings.typeSpeedMs) ms/char",
                            value: $settings.typeSpeedMs,
                            in: 0...200,
                            step: 5
                        )
                        .focusable(false)
                    }

                    if settings.outputMode == .paste {
                        Toggle("Restore clipboard after paste", isOn: $settings.restoreClipboard)
                            .focusable(false)
                    }

                    Stepper(
                        "Send Return delay: \(settings.sendReturnDelayMs) ms",
                        value: $settings.sendReturnDelayMs,
                        in: 0...1000,
                        step: 50
                    )
                    .focusable(false)
                    Text("Delay before pressing Return after output (Talk + Send hotkey)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Section("Recording Overlay") {
                    Toggle("Show overlay while recording", isOn: $settings.showOverlay)
                        .focusable(false)

                    if settings.showOverlay {
                        Picker("Position", selection: $settings.overlayPosition) {
                            ForEach(WhisperSettings.OverlayPosition.allCases, id: \.self) { pos in
                                Text(pos.rawValue).tag(pos)
                            }
                        }
                    }
                }

                Section("Mouse Zone") {
                    Toggle("Enable mouse trigger zone", isOn: $settings.mouseZoneEnabled)
                        .focusable(false)
                    Text("Hover to record + send. Click and drag to reposition.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Section("System") {
                    Toggle("Launch at login", isOn: $settings.launchAtLogin)
                        .focusable(false)
                        .onChange(of: settings.launchAtLogin) { _, enabled in
                            LoginItemManager.setEnabled(enabled)
                        }
                }
            }
            .formStyle(.grouped)
        }
    }


    private var vadTab: some View {
        Form {
            Section("Voice Activity Detection") {
                Toggle("Enable VAD", isOn: $settings.vadEnabled)
                    .focusable(false)
                Text("When enabled, silence is trimmed from audio before transcription")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Neural VAD") {
                Toggle("Silero VAD", isOn: $settings.sileroVADEnabled)
                    .focusable(false)
                Text("Neural speech detection within whisper.cpp — auto-downloads 1.8 MB model on first use")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Thresholds") {
                HStack {
                    Text("Speech threshold")
                    Spacer()
                    Slider(value: $settings.vadSpeechThreshold, in: 0.001...0.1, step: 0.001)
                        .frame(width: 200)
                        .focusable(false)
                    Text(String(format: "%.3f", settings.vadSpeechThreshold))
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
                HStack {
                    Text("Silence threshold")
                    Spacer()
                    Slider(value: $settings.vadSilenceThreshold, in: 0.001...0.05, step: 0.001)
                        .frame(width: 200)
                        .focusable(false)
                    Text(String(format: "%.3f", settings.vadSilenceThreshold))
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
            }

            Section("Durations") {
                Stepper(
                    "Min speech: \(settings.vadMinSpeechMs) ms",
                    value: $settings.vadMinSpeechMs,
                    in: 50...500,
                    step: 25
                )
                .focusable(false)
                Stepper(
                    "Min silence: \(settings.vadMinSilenceMs) ms",
                    value: $settings.vadMinSilenceMs,
                    in: 100...2000,
                    step: 50
                )
                .focusable(false)
            }

            Section("Padding") {
                Stepper(
                    "Pre-speech padding: \(settings.vadPrePaddingMs) ms",
                    value: $settings.vadPrePaddingMs,
                    in: 50...500,
                    step: 25
                )
                .focusable(false)
                Stepper(
                    "Post-speech padding: \(settings.vadPostPaddingMs) ms",
                    value: $settings.vadPostPaddingMs,
                    in: 50...500,
                    step: 25
                )
                .focusable(false)
            }
        }
        .formStyle(.grouped)
        .disabled(!settings.vadEnabled)
    }

    private var advancedTab: some View {
        ScrollView {
            Form {
                Section("Sampling") {
                    Picker("Strategy", selection: $settings.strategy) {
                        ForEach(SamplingStrategy.allCases, id: \.self) { strategy in
                            Text(strategy.rawValue.capitalized).tag(strategy)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("Temperature")
                        Slider(value: $settings.temperature, in: 0.0...1.0, step: 0.05)
                            .focusable(false)
                        Text(String(format: "%.2f", settings.temperature))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }

                    HStack {
                        Text("Temp increment")
                        Slider(value: $settings.temperatureInc, in: 0.0...1.0, step: 0.05)
                            .focusable(false)
                        Text(String(format: "%.2f", settings.temperatureInc))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }

                    if settings.strategy == .greedy {
                        Stepper("Best of: \(settings.bestOf)", value: $settings.bestOf, in: 1...10)
                            .focusable(false)
                    }

                    if settings.strategy == .beamSearch {
                        Stepper("Beam size: \(settings.beamSize)", value: $settings.beamSize, in: 1...10)
                            .focusable(false)
                    }
                }

                Section("Performance") {
                    Stepper(
                        "Threads: \(settings.threadCount == 0 ? "Auto (\(settings.resolvedThreadCount))" : "\(settings.threadCount)")",
                        value: $settings.threadCount,
                        in: 0...16
                    )
                    .focusable(false)
                    Toggle("Use GPU (Metal)", isOn: $settings.useGPU)
                        .focusable(false)
                    Toggle("Flash Attention", isOn: $settings.flashAttention)
                        .focusable(false)
                }

                Section("Behavior") {
                    Toggle("No context (reset between segments)", isOn: $settings.noContext)
                        .focusable(false)
                    Toggle("Single segment mode", isOn: $settings.singleSegment)
                        .focusable(false)
                    Toggle("Suppress blank tokens", isOn: $settings.suppressBlank)
                        .focusable(false)
                    Toggle("Suppress non-speech tokens", isOn: $settings.suppressNonSpeechTokens)
                        .focusable(false)
                    Toggle("Disable timestamps", isOn: $settings.noTimestamps)
                        .focusable(false)
                    Toggle("Token-level timestamps", isOn: $settings.tokenTimestamps)
                        .focusable(false)
                    Toggle("Carry initial prompt across windows", isOn: $settings.carryInitialPrompt)
                        .focusable(false)
                }

                Section("Thresholds") {
                    HStack {
                        Text("Entropy")
                        Spacer()
                        Slider(value: $settings.entropyThreshold, in: 0.0...5.0, step: 0.1)
                            .frame(width: 180)
                            .focusable(false)
                        Text(String(format: "%.1f", settings.entropyThreshold))
                            .monospacedDigit()
                            .frame(width: 35, alignment: .trailing)
                    }
                    HStack {
                        Text("Log prob")
                        Spacer()
                        Slider(value: $settings.logprobThreshold, in: -5.0...0.0, step: 0.1)
                            .frame(width: 180)
                            .focusable(false)
                        Text(String(format: "%.1f", settings.logprobThreshold))
                            .monospacedDigit()
                            .frame(width: 35, alignment: .trailing)
                    }
                    HStack {
                        Text("No speech")
                        Spacer()
                        Slider(value: $settings.noSpeechThreshold, in: 0.0...1.0, step: 0.05)
                            .frame(width: 180)
                            .focusable(false)
                        Text(String(format: "%.2f", settings.noSpeechThreshold))
                            .monospacedDigit()
                            .frame(width: 35, alignment: .trailing)
                    }
                }

                Section("Initial Prompt") {
                    TextEditor(text: $settings.initialPrompt)
                        .focused($promptFieldFocused)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 60)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3))
                        )
                    if settings.initialPrompt.isEmpty {
                        Text("Guide the model with context or vocabulary hints")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

}

class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func showSettings(settings: WhisperSettings, vad: VoiceActivityDetector, modelName: String = "", modelPath: String = "", localModels: [WhisperModel] = [], initialTab: Int? = nil, onChanged: ((WhisperSettings) -> Void)? = nil, onModelDownloaded: (() -> Void)? = nil) {
        if let existing = window {
            activateWindow(existing)
            return
        }

        let settingsView = SettingsView(
            settings: settings,
            vad: vad,
            currentModelName: modelName,
            currentModelPath: modelPath,
            onSettingsChanged: onChanged,
            onModelDownloaded: onModelDownloaded,
            localModels: localModels,
            initialTab: initialTab
        )

        let hostingView = NSHostingView(rootView: settingsView)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Speak Settings"
        newWindow.contentView = hostingView
        newWindow.center()
        newWindow.isReleasedWhenClosed = false

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: newWindow, queue: .main) { [weak self] _ in
            self?.window = nil
            self?.windowDidClose()
        }

        window = newWindow
        activateWindow(newWindow)
    }

    func closeAndReopen() {
        window?.close()
        window = nil
    }

    private func activateWindow(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(window.contentView)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            window.level = .normal
        }
    }

    func windowDidClose() {
        NSApp.setActivationPolicy(.accessory)
    }
}
