import FabCore
import Testing

@Suite("ReplacementDictionary")
struct ReplacementDictionaryTests {
    let dictionary = ReplacementDictionary(entries: [
        .init(pattern: "anthropite", replacement: "Anthropite"),
        .init(pattern: "wisper kit", replacement: "WhisperKit"),
    ])

    @Test func replacesWholeWords() {
        #expect(
            dictionary.apply(to: "i work at anthropite now") == "i work at Anthropite now"
        )
    }

    @Test func isCaseInsensitiveByDefault() {
        #expect(dictionary.apply(to: "ANTHROPITE rocks") == "Anthropite rocks")
    }

    @Test func doesNotReplaceSubstrings() {
        #expect(dictionary.apply(to: "anthropites unite") == "anthropites unite")
    }

    @Test func replacesMultiWordPatterns() {
        #expect(dictionary.apply(to: "we use wisper kit here") == "we use WhisperKit here")
    }

    @Test func replacesMultipleOccurrences() {
        #expect(
            dictionary.apply(to: "anthropite and anthropite") == "Anthropite and Anthropite"
        )
    }

    @Test func caseSensitiveEntryRespectsCase() {
        let strict = ReplacementDictionary(entries: [
            .init(pattern: "ml", replacement: "ML", caseSensitive: true)
        ])
        #expect(strict.apply(to: "ml and Ml") == "ML and Ml")
    }

    @Test func literalSpecialCharactersDoNotBreakMatching() {
        let symbols = ReplacementDictionary(entries: [
            .init(pattern: "c++", replacement: "C++")
        ])
        // "c++" ends in a non-word character, so \b matching applies to the
        // "c"; the pattern itself must be escaped, not treated as regex.
        #expect(symbols.apply(to: "i like c++ a lot") == "i like C++ a lot")
    }

    @Test func replacementWithDollarSignIsLiteral() {
        let money = ReplacementDictionary(entries: [
            .init(pattern: "dollars", replacement: "$$$")
        ])
        #expect(money.apply(to: "ten dollars") == "ten $$$")
    }

    @Test func pipelineRunsStagesInOrder() async throws {
        let pipeline = PostProcessingPipeline(stages: [
            ReplacementDictionary(entries: [.init(pattern: "a", replacement: "b")]),
            ReplacementDictionary(entries: [.init(pattern: "b", replacement: "c")]),
        ])
        #expect(try await pipeline.process("a") == "c")
    }
}

@Suite("ReplacementDictionary caching")
struct ReplacementDictionaryCachingTests {
    @Test func cachedResultMatchesNaive() {
        let dict = ReplacementDictionary(entries: [
            .init(pattern: "whisper kit", replacement: "WhisperKit"),
            .init(pattern: "c++", replacement: "C++", caseSensitive: true),
        ])
        #expect(dict.apply(to: "i love whisper kit and c++") == "i love WhisperKit and C++")
    }

    @Test func mutatingEntriesAfterInitRebuildsCompiledRules() {
        var dict = ReplacementDictionary(entries: [
            .init(pattern: "anthropite", replacement: "Anthropite")
        ])
        dict.entries = [.init(pattern: "parakeet", replacement: "Parakeet")]
        #expect(dict.apply(to: "the parakeet sings") == "the Parakeet sings")
        // Old rule no longer applies once entries are replaced wholesale.
        #expect(dict.apply(to: "anthropite here") == "anthropite here")
    }
}
