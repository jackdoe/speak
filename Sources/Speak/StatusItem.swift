import AppKit

@MainActor final class StatusItem: NSObject {
    enum State {
        case idle, recording, transcribing
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let summary = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let openSettings: () -> Void

    init(openSettings: @escaping () -> Void) {
        self.openSettings = openSettings
        super.init()
        let menu = NSMenu()
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(settings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Speak", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        show(.idle)
    }

    func show(_ state: State) {
        let (symbol, color, label): (String, NSColor?, String) = switch state {
        case .idle: ("mic", nil, "Speak")
        case .recording: ("mic.fill", .systemRed, "Speak: recording")
        case .transcribing: ("waveform", .systemOrange, "Speak: transcribing")
        }
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.button?.contentTintColor = color
    }

    func report(_ line: String) {
        summary.title = line
    }

    @objc private func settings() {
        openSettings()
    }
}
