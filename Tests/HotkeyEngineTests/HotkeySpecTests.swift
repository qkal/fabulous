import CoreGraphics
import Foundation
import HotkeyEngine
import Testing

@Suite("HotkeySpec")
struct HotkeySpecTests {
    @Test func defaultIsPushToTalkRightOption() {
        #expect(HotkeySpec.default.mode == .pushToTalk)
        #expect(HotkeySpec.default.trigger == .modifierHold(.rightOption))
    }

    @Test func modifierHoldSurvivesCodableRoundtrip() throws {
        let spec = HotkeySpec(mode: .toggle, trigger: .modifierHold(.fn))
        let decoded = try JSONDecoder().decode(
            HotkeySpec.self, from: JSONEncoder().encode(spec)
        )
        #expect(decoded == spec)
    }

    @Test func keyChordSurvivesCodableRoundtrip() throws {
        let spec = HotkeySpec(
            mode: .pushToTalk,
            trigger: .keyChord(keyCode: 49, modifiers: [.option, .command])
        )
        let decoded = try JSONDecoder().decode(
            HotkeySpec.self, from: JSONEncoder().encode(spec)
        )
        #expect(decoded == spec)
    }

    @Test func everyModifierRoundtripsThroughItsKeyCode() {
        for modifier in HotkeyModifier.allCases {
            #expect(HotkeyModifier.from(keyCode: modifier.keyCode) == modifier)
        }
    }

    @Test func chordModifiersFromCGFlags() {
        let flags: CGEventFlags = [.maskCommand, .maskAlternate]
        #expect(ChordModifiers(cgFlags: flags) == [.command, .option])
    }

    @Test func chordModifiersIgnoreNonModifierFlags() {
        // Real events carry extra bits (device-dependent, nonCoalesced, …).
        let flags = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x20000100)
        #expect(ChordModifiers(cgFlags: flags) == [.shift])
    }

    @Test func chordDisplayUsesConventionalOrder() {
        let trigger = HotkeyTrigger.keyChord(
            keyCode: 49, modifiers: [.command, .shift, .control, .option]
        )
        #expect(trigger.displayName == "⌃⌥⇧⌘Space")
    }

    @Test func modifierHoldDisplayName() {
        #expect(HotkeyTrigger.modifierHold(.rightOption).displayName == "Right ⌥")
    }

    @Test func unknownKeyCodeGetsFallbackName() {
        #expect(KeyCodeNames.name(for: 999) == "Key 999")
    }

    @Test func functionKeysAreStandalone() {
        #expect(KeyCodeNames.standaloneKeyCodes.contains(96)) // F5
        #expect(!KeyCodeNames.standaloneKeyCodes.contains(0)) // A
    }
}
