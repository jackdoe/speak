import AppKit
import ServiceManagement
import SwiftUI

@MainActor final class SettingsWindow {
    private let microphoneChanged: () -> Void
    private var window: NSWindow?

    init(microphoneChanged: @escaping () -> Void) {
        self.microphoneChanged = microphoneChanged
    }

    func show() {
        let controller = NSHostingController(rootView: SettingsView(devices: AudioDevices.inputs(), microphoneChanged: microphoneChanged))
        let window = window ?? NSWindow(contentViewController: controller)
        window.contentViewController = controller
        window.title = "Speak Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        self.window = window
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    let devices: [AudioDevice]
    let microphoneChanged: () -> Void

    @AppStorage(Microphone.preference) private var microphone = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Picker("Microphone", selection: $microphone) {
                Text("System Default").tag("")
                ForEach(devices) { Text($0.name).tag($0.uid) }
                if !microphone.isEmpty, !devices.contains(where: { $0.uid == microphone }) {
                    Text("Disconnected microphone").tag(microphone)
                }
            }
            Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize()
        .onChange(of: microphone) { microphoneChanged() }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.error("launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
