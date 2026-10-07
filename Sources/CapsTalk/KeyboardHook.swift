import ApplicationServices
import Carbon
import Foundation

final class KeyboardHook {
    static let keyCode = CGKeyCode(kVK_F20)
    var onChange: ((Bool) -> Void)?
    var onInterruption: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var isHeld = false
    private var requiresRelease = false

    func start() throws {
        guard tap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let hook = Unmanaged<KeyboardHook>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                hook.forceRelease()
                hook.onInterruption?()
                if let tap = hook.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(KeyboardHook.keyCode) else {
                return Unmanaged.passUnretained(event)
            }
            if type == .keyUp {
                hook.requiresRelease = false
                if hook.isHeld { hook.isHeld = false; hook.onChange?(false) }
            } else if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0
                && !hook.requiresRelease && !IsSecureEventInputEnabled() && !hook.isHeld {
                hook.isHeld = true
                hook.onChange?(true)
            }
            return nil // Consume F20, including repeats and releases, before other apps see it.
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw AppError("Cannot capture Caps Lock. Enable CapsTalk in Accessibility and Input Monitoring, then retry.")
        }
        self.tap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            stop()
            throw AppError("Cannot start the keyboard event listener.")
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        requiresRelease = CGEventSource.keyState(.hidSystemState, key: Self.keyCode)
    }

    func forceRelease() {
        if isHeld { isHeld = false; requiresRelease = true; onChange?(false) }
    }

    func checkRelease() {
        if isHeld && !CGEventSource.keyState(.hidSystemState, key: Self.keyCode) {
            forceRelease()
            requiresRelease = false
        }
        if requiresRelease && !CGEventSource.keyState(.hidSystemState, key: Self.keyCode) { requiresRelease = false }
    }

    func stop() {
        forceRelease()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }
}
