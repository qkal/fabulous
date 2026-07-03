import PostProcessing
import Testing

struct CleanupPromptBuilderTests {
    @Test func containsCoreCleanupRules() {
        let instructions = CleanupPromptBuilder.instructions(vocabulary: [], appName: nil)
        #expect(instructions.contains("filler"))
        #expect(instructions.contains("new paragraph"))
        #expect(instructions.contains("scratch that"))
        #expect(instructions.contains("quote"))
        #expect(instructions.contains("Never add content"))
    }

    @Test func vocabularyListedWhenPresent() {
        let instructions = CleanupPromptBuilder.instructions(
            vocabulary: ["Anthropic", "WhisperKit"], appName: nil
        )
        #expect(instructions.contains("Anthropic"))
        #expect(instructions.contains("WhisperKit"))
    }

    @Test func vocabularySectionOmittedWhenEmpty() {
        let instructions = CleanupPromptBuilder.instructions(vocabulary: [], appName: nil)
        #expect(!instructions.contains("Prefer these spellings"))
    }

    @Test func appHintPresentOnlyWhenKnown() {
        let with = CleanupPromptBuilder.instructions(vocabulary: [], appName: "Xcode")
        let without = CleanupPromptBuilder.instructions(vocabulary: [], appName: nil)
        #expect(with.contains("Xcode"))
        #expect(!without.contains("destined for"))
    }
}
