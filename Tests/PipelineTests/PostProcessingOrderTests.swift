import FabCore
import Testing

/// Stands in for the LLM stage.
private struct FakeCleanup: TextPostProcessor {
    func process(_ text: String) async throws -> String {
        text.replacingOccurrences(of: "um ", with: "")
    }
}

struct PostProcessingOrderTests {
    @Test func replacementsApplyToLLMOutput() async throws {
        let replacements = ReplacementDictionary(entries: [
            .init(pattern: "anthropic", replacement: "Anthropic")
        ])
        let pipeline = PostProcessingPipeline(stages: [FakeCleanup(), replacements])
        let result = try await pipeline.process("um anthropic ships")
        #expect(result == "Anthropic ships")
    }
}
