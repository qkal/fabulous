import AppKit
import CoreGraphics
import Foundation

/// Watches for the dictation hotkey system-wide and reports raw press/release
/// transitions. Mode semantics (push-to-talk vs toggle) are the caller's job.
///
/// Primary implementation is a `CGEventTap`, which needs Accessibility
/// permission but sees every modifier transition. If the tap can't be created
/// (permission missing or revoked), falls back to
/// `NSEvent.addGlobalMonitorForEvents`, which delivers `.flagsChanged`
/// without special permissions.
@MainActor
public final class HotkeyMonitor {
    public enum Backend: String, Sendable {
        case eventTap
        case globalMonitor
        case none
    }

    public var onPressBegan: (() -> Void)?
    public var onPressEnded: (() -> Void)?

    public private(set) var backend: Backend = .none
    public private(set) var spec: HotkeySpec = .default

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var isPressed = false

    public init() {}

    /// (Re)starts monitoring with the given spec. Safe to call repeatedly.
    public func start(spec: HotkeySpec) {
        stop()
        self.spec = spec
        if startEventTap() {
            backend = .eventTap
        } else if startGlobalMonitor() {
            backend = .globalMonitor
        } else {
            backend = .none
        }
    }

    public func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
        backend = .none
        isPressed = false
    }

    // MARK: - Event tap backend

    private func startEventTap() -> Bool {
        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        // An active (default) tap only needs Accessibility, which we require
        // anyway for text injection; a listen-only tap would additionally
        // need Input Monitoring. We pass every event through unmodified.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    fileprivate func handleTapEvent(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disables taps that stall; re-arm immediately.
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
        case .flagsChanged:
            handleFlagsChanged(keyCode: keyCode, flags: flags)
        default:
            break
        }
    }

    // MARK: - Global monitor fallback

    private func startGlobalMonitor() -> Bool {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Global monitor handlers run on the main thread.
            self?.handleFlagsChanged(
                keyCode: Int64(event.keyCode),
                flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            )
        }
        return globalMonitor != nil
    }

    // MARK: - Shared press/release detection

    private func handleFlagsChanged(keyCode: Int64, flags: CGEventFlags) {
        guard keyCode == spec.modifier.keyCode else { return }
        let isDown = flags.contains(spec.modifier.flagMask)
        if isDown, !isPressed {
            isPressed = true
            onPressBegan?()
        } else if !isDown, isPressed {
            isPressed = false
            onPressEnded?()
        }
    }
}

/// C-function trampoline for the event tap. The tap's run-loop source is
/// scheduled on the main run loop, so this always executes on the main
/// thread; `assumeIsolated` makes that visible to the compiler. The CGEvent
/// itself is not Sendable, so the fields we need are extracted before
/// crossing into the isolated closure.
private func hotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        MainActor.assumeIsolated {
            monitor.handleTapEvent(type: type, keyCode: keyCode, flags: flags)
        }
    }
    return Unmanaged.passUnretained(event)
}
