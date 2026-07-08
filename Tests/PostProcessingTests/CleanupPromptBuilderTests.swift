import PostProcessing
import Testing

struct CleanupPromptBuilderTests {
    @Test func instructionsOpenWithConservativeMandate() {
        let text = CleanupPromptBuilder.instructions(
            userVocabulary: [], screenTerms: [], appName: nil
        )
        #expect(text.contains("Apply only the rules below"))
        #expect(text.contains("keep that part word-for-word"))
        #expect(!text.contains("MUST actively transform"))
    }

    @Test func containsCoreCleanupRules() {
        let instructions = CleanupPromptBuilder.instructions(
            userVocabulary: [], screenTerms: [], appName: nil
        )
        #expect(instructions.contains("filler"))
        #expect(instructions.contains("new paragraph"))
        #expect(instructions.contains("scratch that"))
        #expect(instructions.contains("quote"))
        #expect(instructions.contains("Never add content"))
    }

    @Test func vocabularyListedWhenPresent() {
        let instructions = CleanupPromptBuilder.instructions(
            userVocabulary: ["Anthropic", "WhisperKit"], screenTerms: [], appName: nil
        )
        #expect(instructions.contains("Anthropic"))
        #expect(instructions.contains("WhisperKit"))
    }

    @Test func vocabularySectionOmittedWhenEmpty() {
        let instructions = CleanupPromptBuilder.instructions(
            userVocabulary: [], screenTerms: [], appName: nil
        )
        #expect(!instructions.contains("Prefer these spellings"))
    }

    @Test func appHintPresentOnlyWhenKnown() {
        let with = CleanupPromptBuilder.instructions(
            userVocabulary: [], screenTerms: [], appName: "Xcode"
        )
        let without = CleanupPromptBuilder.instructions(
            userVocabulary: [], screenTerms: [], appName: nil
        )
        #expect(with.contains("Xcode"))
        #expect(!without.contains("destined for"))
    }
}

/// F6: screen-harvested terms must never carry homophone-substitution
/// authority — only user vocabulary can rewrite a dictated word. Screen
/// terms get a softer bias-only clause instead.
@Suite("CleanupPromptBuilder authority scoping")
struct CleanupPromptBuilderAuthorityTests {
    @Test func userVocabularyGetsSubstitutionAuthority() {
        let s = CleanupPromptBuilder.instructions(
            userVocabulary: ["WhisperKit"], screenTerms: [], appName: nil
        )
        #expect(s.contains("replace the homophone"))
        #expect(s.contains("WhisperKit"))
    }

    @Test func screenTermsAreBiasOnlyNeverSubstitutionAuthority() {
        let s = CleanupPromptBuilder.instructions(
            userVocabulary: [], screenTerms: ["paypa1"], appName: nil
        )
        // Screen term appears only in the soft-bias block, not the substitution clause.
        #expect(s.contains("paypa1"))
        #expect(!s.contains("replace the homophone"))
    }

    @Test func appNameIsQuotedData() {
        let s = CleanupPromptBuilder.instructions(
            userVocabulary: [], screenTerms: [], appName: "Terminal"
        )
        #expect(s.contains("\"Terminal\""))
    }

    // A harvested term containing a `"` must stay inside its delimiters — the
    // inner quote is escaped, so it can't close the wrapper and inject text
    // into the prompt body (residual F6 quote-breakout).
    @Test func embeddedQuoteInScreenTermIsEscaped() {
        let s = CleanupPromptBuilder.instructions(
            userVocabulary: [], screenTerms: [#"Report "Q1""#], appName: nil
        )
        #expect(s.contains(#""Report \"Q1\"""#))
    }

    @Test func embeddedQuoteInAppNameIsEscaped() {
        let s = CleanupPromptBuilder.instructions(
            userVocabulary: [], screenTerms: [], appName: #"Weird"App"#
        )
        #expect(s.contains(#""Weird\"App""#))
    }

    // A term ending in `\` must not consume the closing quote — the backslash
    // is escaped first, so quote-only escaping can't be defeated.
    @Test func trailingBackslashInScreenTermCannotBreakOut() {
        let s = CleanupPromptBuilder.instructions(
            userVocabulary: [], screenTerms: [#"path\"#], appName: nil
        )
        #expect(s.contains(#""path\\""#))
    }
}
