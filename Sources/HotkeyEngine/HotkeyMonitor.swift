import AppKit
import CoreGraphics
import Foundation

/// Watches for the dictation hotkey system-wide and reports raw press/release
/// transitions. Mode semantics (push-to-talk vs toggle) are the caller's job.
///
/// Primary implementation is a `CGEventTap`, which needs Accessibility
/// permission but sees every keystroke and can swallow matched key chords so
/// they don't also type into the focused app. If the tap can't be created
/// (permission missing or revoked), falls back to
/// `NSEvent.addGlobalMonitorForEvents` — modifier-hold triggers work there
/// without extra permissions, but chords can't be swallowed and key events
/// may require Input Monitoring.
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

    /// While true (hotkey recorder UI is capturing), events pass through
    /// untouched and no callbacks fire.
    public var isSuspended = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitors: [Any] = []
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
        for monitor in globalMonitors {
            NSEvent.removeMonitor(monitor)
        }
        globalMonitors = []
        backend = .none
        isPressed = false
    }

    // MARK: - Event tap backend

    private var eventMask: CGEventMask {
        switch spec.trigger {
        case .modifierHold:
            CGEventMask(1) << CGEventType.flagsChanged.rawValue
        case .keyChord:
            CGEventMask(1) << CGEventType.keyDown.rawValue
                | CGEventMask(1) << CGEventType.keyUp.rawValue
        }
    }

    private func startEventTap() -> Bool {
        // An active (default) tap only needs Accessibility, which we require
        // anyway for text injection; a listen-only tap would additionally
        // need Input Monitoring. Active also lets us swallow chord events.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
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

    /// Returns true when the event was consumed and must not reach the
    /// focused app.
    fileprivate func handleTapEvent(
        type: CGEventType, keyCode: Int64, flags: CGEventFlags, isAutorepeat: Bool
    ) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disables taps that stall; re-arm immediately.
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return false
        case .flagsChanged, .keyDown, .keyUp:
            guard !isSuspended else { return false }
            return handleKeyEvent(
                type: type, keyCode: keyCode, flags: flags, isAutorepeat: isAutorepeat
            )
        default:
            return false
        }
    }

    // MARK: - Global monitor fallback

    private func startGlobalMonitor() -> Bool {
        let mask: NSEvent.EventTypeMask = switch spec.trigger {
        case .modifierHold: .flagsChanged
        case .keyChord: [.keyDown, .keyUp]
        }
        // Global monitor handlers run on the main thread. Events can't be
        // swallowed from here — chords will also reach the focused app.
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, !isSuspended else { return }
            let type: CGEventType = switch event.type {
            case .keyDown: .keyDown
            case .keyUp: .keyUp
            default: .flagsChanged
            }
            _ = handleKeyEvent(
                type: type,
                keyCode: Int64(event.keyCode),
                flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)),
                isAutorepeat: event.type == .keyDown && event.isARepeat
            )
        }
        guard let monitor else { return false }
        globalMonitors = [monitor]
        return true
    }

    // MARK: - Shared press/release detection

    private func handleKeyEvent(
        type: CGEventType, keyCode: Int64, flags: CGEventFlags, isAutorepeat: Bool
    ) -> Bool {
        switch spec.trigger {
        case let .modifierHold(modifier):
            guard type == .flagsChanged, keyCode == modifier.keyCode else { return false }
            setPressed(flags.contains(modifier.flagMask))
            return false // modifier transitions always pass through

        case let .keyChord(chordKeyCode, modifiers):
            guard keyCode == chordKeyCode else { return false }
            switch type {
            case .keyDown:
                guard ChordModifiers(cgFlags: flags) == modifiers else { return false }
                if isAutorepeat {
                    // Swallow repeats while held so they don't type.
                    return isPressed
                }
                setPressed(true)
                return true
            case .keyUp:
                // Match the release even if modifiers were let go first.
                guard isPressed else { return false }
                setPressed(false)
                return true
            default:
                return false
            }
        }
    }

    private func setPressed(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        if pressed {
            onPressBegan?()
        } else {
            onPressEnded?()
        }
    }
}

/// C-function trampoline for the event tap. The tap's run-loop source is
/// scheduled on the main run loop, so this always executes on the main
/// thread; `assumeIsolated` makes that visible to the compiler. The CGEvent
/// itself is not Sendable, so the fields we need are extracted before
/// crossing into the isolated closure. Returning nil consumes the event.
private func hotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let swallow = MainActor.assumeIsolated {
        monitor.handleTapEvent(
            type: type, keyCode: keyCode, flags: flags, isAutorepeat: isAutorepeat
        )
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
