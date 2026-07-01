import Testing
import TextInjector

@Suite("StrategySelector")
struct StrategySelectionTests {
    let selector = StrategySelector()

    private func context(
        bundleID: String? = "com.apple.Notes",
        secureInput: Bool = false,
        trusted: Bool = true
    ) -> InjectionContext {
        InjectionContext(
            frontmostBundleID: bundleID,
            secureInputActive: secureInput,
            accessibilityTrusted: trusted
        )
    }

    @Test func defaultChainStartsWithAXInsert() {
        #expect(
            selector.select(for: context())
                == .attempt(chain: [.axInsert, .paste, .keystrokes])
        )
    }

    @Test func secureInputRefusesOutright() {
        #expect(
            selector.select(for: context(secureInput: true))
                == .refuse(.secureInputActive)
        )
    }

    @Test func secureInputWinsOverMissingAccessibility() {
        // Refusing for secure input is the more actionable message.
        #expect(
            selector.select(for: context(secureInput: true, trusted: false))
                == .refuse(.secureInputActive)
        )
    }

    @Test func missingAccessibilityRefuses() {
        #expect(
            selector.select(for: context(trusted: false))
                == .refuse(.accessibilityNotGranted)
        )
    }

    @Test func terminalOverrideSkipsAXInsert() {
        #expect(
            selector.select(for: context(bundleID: "com.apple.Terminal"))
                == .attempt(chain: [.paste, .keystrokes])
        )
    }

    @Test func unknownFrontmostAppUsesDefaultChain() {
        #expect(
            selector.select(for: context(bundleID: nil))
                == .attempt(chain: [.axInsert, .paste, .keystrokes])
        )
    }

    @Test func customOverrideToKeystrokesYieldsSingleStrategy() {
        let custom = StrategySelector(overrides: ["com.example.stubborn": .keystrokes])
        #expect(
            custom.select(for: context(bundleID: "com.example.stubborn"))
                == .attempt(chain: [.keystrokes])
        )
    }

    @Test func chainsNeverPromoteBackToCleanerStrategies() {
        #expect(StrategySelector.chain(startingAt: .paste) == [.paste, .keystrokes])
        #expect(StrategySelector.chain(startingAt: .keystrokes) == [.keystrokes])
    }
}
