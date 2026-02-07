import Cocoa
import CoreGraphics

class HotkeyManager {
    var onKeyDown: ((_ isSend: Bool) -> Void)?
    var onKeyUp: ((_ isSend: Bool) -> Void)?
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    fileprivate var isKeyDown = false
    fileprivate var activeKeyWasSend = false

    var isRunning: Bool { eventTap != nil }

    fileprivate var primaryKeyCode: UInt16 = 0x6F
    fileprivate var sendKeyCode: UInt16 = 0x67

    func setKeyCodes(primary: UInt16, send: UInt16) {
        primaryKeyCode = primary
        sendKeyCode = send
    }

    func start() -> Bool {
        guard eventTap == nil else { return true }

        guard CGPreflightListenEventAccess() else {
            CGRequestListenEventAccess()
            return false
        }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: selfPtr
        ) else {
            Unmanaged<HotkeyManager>.fromOpaque(selfPtr).release()
            NSLog("[HotkeyManager] Failed to create event tap.")
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        NSLog("[HotkeyManager] Listening for keycodes %d (primary) and %d (send)", primaryKeyCode, sendKeyCode)
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if eventTap != nil {
            Unmanaged<HotkeyManager>.passUnretained(self).release()
        }
        eventTap = nil
        runLoopSource = nil
        isKeyDown = false
    }

    static func checkPermission() -> Bool {
        CGPreflightListenEventAccess()
    }

    static func requestPermission() {
        CGRequestListenEventAccess()
    }

    deinit { stop() }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout {
        if let tap = manager.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

    let isPrimary = keyCode == manager.primaryKeyCode
    let isSend = keyCode == manager.sendKeyCode

    guard isPrimary || isSend else {
        return Unmanaged.passUnretained(event)
    }

    if type == .keyDown {
        if !manager.isKeyDown {
            manager.isKeyDown = true
            manager.activeKeyWasSend = isSend
            DispatchQueue.main.async { manager.onKeyDown?(isSend) }
        }
    } else if type == .keyUp {
        let wasSend = manager.activeKeyWasSend
        manager.isKeyDown = false
        DispatchQueue.main.async { manager.onKeyUp?(wasSend) }
    }

    return nil
}
