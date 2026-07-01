import CoreGraphics
import Foundation

/// A modifier key usable as a dictation hotkey, distinguished left/right by
/// hardware key code (the CGEventFlags masks alone can't tell them apart).
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

/// The user's hotkey configuration. v1 supports modifier-hold chords;
/// key-plus-modifier combos and double-tap gestures come with the recorder
/// UI in a later phase.
public struct HotkeySpec: Sendable, Codable, Equatable {
    public enum Mode: String, Sendable, Codable {
        /// Hold to record, release to transcribe.
        case pushToTalk
        /// Tap to start, tap again to stop.
        case toggle
    }

    public var mode: Mode
    public var modifier: HotkeyModifier

    public init(mode: Mode, modifier: HotkeyModifier) {
        self.mode = mode
        self.modifier = modifier
    }

    public static let `default` = HotkeySpec(mode: .pushToTalk, modifier: .rightOption)
}
