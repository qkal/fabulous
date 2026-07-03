import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FabCore
import Foundation

public enum InjectionError: Error, Sendable, Equatable {
    case refused(RefusalReason)
    case allStrategiesFailed
}

/// Inserts text into whatever app has focus, via the strategy chain decided
/// by `StrategySelector`. Main-actor: AX calls, NSPasteboard, and event
/// posting all want the main thread.
@MainActor
public final class TextInjector {
    private let selector: StrategySelector

    public init(selector: StrategySelector = StrategySelector()) {
        self.selector = selector
    }

    /// Returns the strategy that succeeded.
    @discardableResult
    public func inject(_ text: String) async throws -> InjectionStrategy {
        guard !text.isEmpty else { throw InjectionError.allStrategiesFailed }

        let context = InjectionContext(
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            secureInputActive: IsSecureEventInputEnabled(),
            accessibilityTrusted: AXIsProcessTrusted()
        )

        switch selector.select(for: context) {
        case let .refuse(reason):
            throw InjectionError.refused(reason)
        case let .attempt(chain):
            for strategy in chain {
                let succeeded = switch strategy {
                case .axInsert: attemptAXInsert(text)
                case .paste: await attemptPaste(text)
                case .keystrokes: await attemptKeystrokes(text)
                }
                if succeeded { return strategy }
            }
            throw InjectionError.allStrategiesFailed
        }
    }

    // MARK: - Strategy 1: Accessibility insert

    private func attemptAXInsert(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
            let focusedRef,
            CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return false }

        let element = unsafeDowncast(focusedRef, to: AXUIElement.self)

        // Setting kAXSelectedText replaces the selection, or inserts at the
        // caret when the selection is empty — exactly dictation semantics.
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable
        ) == .success, settable.boolValue else { return false }

        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString
        ) == .success
    }

    // MARK: - Strategy 2: paste simulation

    private func attemptPaste(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        // v1 preserves plain-text clipboard contents only; rich content
        // (images, files) is lost on restore. Documented limitation.
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        // Give the pasteboard server a beat before the app reads it.
        try? await Task.sleep(for: .milliseconds(50))

        guard postKeystroke(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand) else {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
            return false
        }

        // Wait for the target app to service the paste, then restore —
        // unless something else wrote to the clipboard in the meantime.
        try? await Task.sleep(for: .milliseconds(300))
        if pasteboard.changeCount == ourChangeCount, let saved {
            pasteboard.clearContents()
            pasteboard.setString(saved, forType: .string)
        }
        return true
    }

    // MARK: - Strategy 3: keystroke synthesis

    private func attemptKeystrokes(_ text: String) async -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }
        for segment in KeystrokeSegmenter.segments(of: text) {
            switch segment {
            case .newline:
                guard postKeystroke(keyCode: CGKeyCode(kVK_Return), flags: []) else {
                    return false
                }
                try? await Task.sleep(for: .milliseconds(5))
            case let .text(run):
                guard await postUnicodeString(run, source: source) else {
                    return false
                }
            }
        }
        return true
    }

    private func postUnicodeString(_ text: String, source: CGEventSource) async -> Bool {
        let units = Array(text.utf16)
        // keyboardSetUnicodeString caps out around 20 UTF-16 units per event.
        let chunkSize = 20
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + chunkSize, units.count)])
            guard
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return false }
            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(
                    stringLength: chunk.count, unicodeString: buffer.baseAddress
                )
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            index += chunkSize
            // Some apps drop events posted faster than they can process.
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func postKeystroke(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
