import SwiftUI
import AppKit
import Observation

@Observable
class StatusBarController {
    enum AppState: String {
        case idle = "Idle"
        case recording = "Recording..."
        case transcribing = "Transcribing..."
    }

    var state: AppState = .idle {
        didSet { rebuildMenu(); updateIcon() }
    }

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var models: [String] = []
    private var currentModelName: String?

    var isMicWarm: Bool = false {
        didSet { rebuildMenu() }
    }
    var isContinuousMode: Bool = false {
        didSet { rebuildMenu() }
    }

    var onSettingsClicked: (() -> Void)?
    var onModelSelected: ((String) -> Void)?
    var onDownloadMoreClicked: (() -> Void)?
    var onMicWarmToggled: ((Bool) -> Void)?
    var onContinuousModeToggled: ((Bool) -> Void)?
    var onSetupClicked: (() -> Void)?

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        rebuildMenu()
        statusItem.menu = menu
    }

    func updateIcon() {
        guard let button = statusItem?.button else { return }

        let symbolName: String
        switch state {
        case .idle:
            symbolName = "mic"
        case .recording:
            symbolName = "mic.fill"
        case .transcribing:
            symbolName = "ellipsis.circle"
        }

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: state.rawValue) {
            image.isTemplate = true
            button.image = image
        }
    }

    func updateModelsSubmenu(models: [String], current: String?) {
        self.models = models
        self.currentModelName = current
        rebuildMenu()
    }

    private func rebuildMenu() {
        let newMenu = NSMenu()

        let modelsItem = NSMenuItem(title: "Models", action: nil, keyEquivalent: "")
        let modelsSubmenu = NSMenu()

        if models.isEmpty {
            let noneItem = NSMenuItem(title: "No models found", action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            modelsSubmenu.addItem(noneItem)
        } else {
            for model in models {
                let item = NSMenuItem(title: model, action: #selector(modelMenuItemClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = model
                if model == currentModelName {
                    item.state = .on
                }
                modelsSubmenu.addItem(item)
            }
        }

        modelsSubmenu.addItem(NSMenuItem.separator())
        let downloadItem = NSMenuItem(title: "Download More...", action: #selector(downloadMoreClicked(_:)), keyEquivalent: "")
        downloadItem.target = self
        modelsSubmenu.addItem(downloadItem)

        modelsItem.submenu = modelsSubmenu
        newMenu.addItem(modelsItem)

        newMenu.addItem(NSMenuItem.separator())

        let continuousItem = NSMenuItem(title: "Continuous Mode", action: #selector(continuousModeToggled(_:)), keyEquivalent: "")
        continuousItem.target = self
        continuousItem.state = isContinuousMode ? .on : .off
        newMenu.addItem(continuousItem)

        let micWarmItem = NSMenuItem(title: "Keep Mic Warm", action: #selector(micWarmToggled(_:)), keyEquivalent: "")
        micWarmItem.target = self
        micWarmItem.state = isMicWarm ? .on : .off
        newMenu.addItem(micWarmItem)

        newMenu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(settingsClicked(_:)), keyEquivalent: ",")
        settingsItem.target = self
        newMenu.addItem(settingsItem)

        newMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Speak", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        newMenu.addItem(quitItem)

        menu = newMenu
        self.statusItem?.menu = newMenu
    }

    @objc private func settingsClicked(_ sender: NSMenuItem) {
        NSLog("[StatusBar] Settings clicked")
        onSettingsClicked?()
    }

    @objc private func continuousModeToggled(_ sender: NSMenuItem) {
        isContinuousMode.toggle()
        onContinuousModeToggled?(isContinuousMode)
    }

    @objc private func micWarmToggled(_ sender: NSMenuItem) {
        isMicWarm.toggle()
        onMicWarmToggled?(isMicWarm)
    }

    @objc private func setupClicked(_ sender: NSMenuItem) {
        onSetupClicked?()
    }

    @objc private func downloadMoreClicked(_ sender: NSMenuItem) {
        onDownloadMoreClicked?()
    }

    @objc private func modelMenuItemClicked(_ sender: NSMenuItem) {
        guard let modelName = sender.representedObject as? String else { return }
        NSLog("[StatusBar] Model selected: %@", modelName)
        currentModelName = modelName
        rebuildMenu()
        onModelSelected?(modelName)
    }
}
