import CoreGraphics
import Foundation

/// A modifier key usable as a hold-to-talk hotkey, distinguished left/right
/// by hardware key code (the CGEventFlags masks alone can't tell them apart).
public enum HotkeyModifier: String, Sendable, Codable, CaseIterable {
    case leftCommand, rightCommand
    case leftOption, rightOption
    case leftControl, rightControl
    case leftShift, rightShift
    case fn

    public var keyCode: Int64 {
        switch self {
        case .leftCommand: 55
        case .rightCommand: 54
        case .leftOption: 58
        case .rightOption: 61
        case .leftControl: 59
        case .rightControl: 62
        case .leftShift: 56
        case .rightShift: 60
        case .fn: 63
        }
    }

    public static func from(keyCode: Int64) -> HotkeyModifier? {
        allCases.first { $0.keyCode == keyCode }
    }

    public var flagMask: CGEventFlags {
        switch self {
        case .leftCommand, .rightCommand: .maskCommand
        case .leftOption, .rightOption: .maskAlternate
        case .leftControl, .rightControl: .maskControl
        case .leftShift, .rightShift: .maskShift
        case .fn: .maskSecondaryFn
        }
    }

    public var displayName: String {
        switch self {
        case .leftCommand: "Left ⌘"
        case .rightCommand: "Right ⌘"
        case .leftOption: "Left ⌥"
        case .rightOption: "Right ⌥"
        case .leftControl: "Left ⌃"
        case .rightControl: "Right ⌃"
        case .leftShift: "Left ⇧"
        case .rightShift: "Right ⇧"
        case .fn: "Fn 🌐"
        }
    }
}

/// Side-insensitive modifier set for key chords (⌥Space doesn't care which
/// Option key you used).
public struct ChordModifiers: OptionSet, Sendable, Codable, Equatable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let control = ChordModifiers(rawValue: 1 << 0)
    public static let option = ChordModifiers(rawValue: 1 << 1)
    public static let shift = ChordModifiers(rawValue: 1 << 2)
    public static let command = ChordModifiers(rawValue: 1 << 3)
    public static let fn = ChordModifiers(rawValue: 1 << 4)

    public init(cgFlags: CGEventFlags) {
        var set = ChordModifiers()
        if cgFlags.contains(.maskControl) { set.insert(.control) }
        if cgFlags.contains(.maskAlternate) { set.insert(.option) }
        if cgFlags.contains(.maskShift) { set.insert(.shift) }
        if cgFlags.contains(.maskCommand) { set.insert(.command) }
        if cgFlags.contains(.maskSecondaryFn) { set.insert(.fn) }
        self = set
    }

    /// Standard macOS ordering: ⌃ ⌥ ⇧ ⌘, Fn first.
    public var displayString: String {
        var out = ""
        if contains(.fn) { out += "🌐" }
        if contains(.control) { out += "⌃" }
        if contains(.option) { out += "⌥" }
        if contains(.shift) { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }
}

/// What physically activates dictation.
public enum HotkeyTrigger: Sendable, Codable, Equatable {
    /// Hold a single modifier key (e.g. Right ⌥). Press = flagsChanged with
    /// that key's code; the event always passes through to the system.
    case modifierHold(HotkeyModifier)
    /// A regular key plus modifiers (e.g. ⌥Space). The matching key events
    /// are swallowed so the chord doesn't also type into the focused app.
    case keyChord(keyCode: Int64, modifiers: ChordModifiers)

    public var displayName: String {
        switch self {
        case let .modifierHold(modifier):
            modifier.displayName
        case let .keyChord(keyCode, modifiers):
            modifiers.displayString + KeyCodeNames.name(for: keyCode)
        }
    }
}

/// The user's hotkey configuration.
public struct HotkeySpec: Sendable, Codable, Equatable {
    public enum Mode: String, Sendable, Codable, CaseIterable {
        /// Hold to record, release to transcribe.
        case pushToTalk
        /// Tap to start, tap again to stop.
        case toggle

        public var displayName: String {
            switch self {
            case .pushToTalk: "Hold to talk"
            case .toggle: "Tap to start/stop"
            }
        }
    }

    public var mode: Mode
    public var trigger: HotkeyTrigger

    public init(mode: Mode, trigger: HotkeyTrigger) {
        self.mode = mode
        self.trigger = trigger
    }

    public var displayName: String { trigger.displayName }

    public static let `default` = HotkeySpec(
        mode: .pushToTalk, trigger: .modifierHold(.rightOption)
    )
}
