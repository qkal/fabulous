import AppKit
import HotkeyEngine

/// Captures the next hotkey the user presses inside the settings window,
/// via a local event monitor (our window is key while recording).
///
/// Semantics: a plain modifier pressed and released with no other key in
/// between becomes a `.modifierHold`; any real key becomes a `.keyChord`
/// with whatever modifiers were down. Escape (unmodified) cancels. Ordinary
/// keys without modifiers are rejected (they'd hijack typing), except keys
/// that are safe standalone (F-keys).
@MainActor
final class KeyCaptureSession {
    private var monitor: Any?
    private var candidateModifier: HotkeyModifier?

    var isActive: Bool { monitor != nil }

    /// `onResult` fires exactly once: with the captured trigger, or nil on
    /// cancel.
    func begin(onResult: @escaping (HotkeyTrigger?) -> Void) {
        end()
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown:
                let keyCode = Int64(event.keyCode)
                let modifiers = ChordModifiers(
                    cgFlags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
                )
                if keyCode == 53, modifiers.isEmpty { // Escape cancels
                    end()
                    onResult(nil)
                    return nil
                }
                if modifiers.isEmpty, !KeyCodeNames.standaloneKeyCodes.contains(keyCode) {
                    NSSound.beep() // needs a modifier; keep capturing
                    return nil
                }
                end()
                onResult(.keyChord(keyCode: keyCode, modifiers: modifiers))
                return nil

            case .flagsChanged:
                let keyCode = Int64(event.keyCode)
                guard let modifier = HotkeyModifier.from(keyCode: keyCode) else { return nil }
                let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
                if flags.contains(modifier.flagMask) {
                    candidateModifier = modifier
                } else if candidateModifier == modifier {
                    // Pressed and released cleanly → modifier-hold hotkey.
                    end()
                    onResult(.modifierHold(modifier))
                }
                return nil

            default:
                return event
            }
        }
    }

    func end() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        candidateModifier = nil
    }
}
