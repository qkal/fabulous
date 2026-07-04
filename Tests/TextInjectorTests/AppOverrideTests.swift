import Foundation
import Testing
@testable import TextInjector

@Suite("AppOverride merging")
struct AppOverrideMergeTests {
    @Test func userOverrideWinsOverBuiltIn() {
        // iTerm2 is a built-in paste override; the user forces it back to
        // axInsert — the only way to neutralize a built-in (spec).
        let selector = StrategySelector(userOverrides: [
            .init(bundleID: "com.googlecode.iterm2", displayName: "iTerm2", strategy: .axInsert)
        ])
        #expect(selector.overrides["com.googlecode.iterm2"] == .axInsert)
    }

    @Test func builtInsSurviveUnrelatedUserEntries() {
        let selector = StrategySelector(userOverrides: [
            .init(bundleID: "com.example.editor", displayName: "Editor", strategy: .keystrokes)
        ])
        #expect(selector.overrides["com.apple.Terminal"] == .paste)
        #expect(selector.overrides["com.example.editor"] == .keystrokes)
    }

    @Test func emptyUserListYieldsBuiltInsExactly() {
        // Deleting the last user row reverts to stock behavior.
        #expect(
            StrategySelector(userOverrides: []).overrides
                == StrategySelector.defaultOverrides
        )
    }

    @Test func laterDuplicateWins() {
        let selector = StrategySelector(userOverrides: [
            .init(bundleID: "com.example.app", displayName: "App", strategy: .paste),
            .init(bundleID: "com.example.app", displayName: "App", strategy: .keystrokes),
        ])
        #expect(selector.overrides["com.example.app"] == .keystrokes)
    }

    @Test func selectionUsesMergedUserOverride() {
        // End to end through select(for:): override sets the chain START;
        // fallback below it still applies.
        let selector = StrategySelector(userOverrides: [
            .init(bundleID: "com.example.editor", displayName: "Editor", strategy: .paste)
        ])
        let context = InjectionContext(
            frontmostBundleID: "com.example.editor",
            secureInputActive: false,
            accessibilityTrusted: true
        )
        #expect(selector.select(for: context) == .attempt(chain: [.paste, .keystrokes]))
    }
}

@Suite("AppOverride codec")
struct AppOverrideCodecTests {
    @Test func roundTrips() throws {
        let entries = [
            AppOverride(bundleID: "com.example.a", displayName: "A", strategy: .axInsert),
            AppOverride(bundleID: "com.example.b", displayName: "B", strategy: .paste),
        ]
        let data = try JSONEncoder().encode(entries)
        let decoded = try JSONDecoder().decode([AppOverride].self, from: data)
        #expect(decoded == entries)
    }

    @Test func corruptBlobDecodesToNil() {
        // SettingsStore falls back to [] via try? — garbage must not trap.
        let garbage = Data("not json at all".utf8)
        #expect((try? JSONDecoder().decode([AppOverride].self, from: garbage)) == nil)
    }
}
