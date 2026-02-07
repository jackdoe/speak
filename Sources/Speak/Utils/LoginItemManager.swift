import ServiceManagement

enum LoginItemManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                NSLog("[LoginItem] Registered as login item")
            } else {
                try SMAppService.mainApp.unregister()
                NSLog("[LoginItem] Unregistered from login items")
            }
        } catch {
            NSLog("[LoginItem] Failed to %@: %@", enabled ? "register" : "unregister", error.localizedDescription)
        }
    }
}
