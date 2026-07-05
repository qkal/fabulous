import FabCore
import Testing

@Suite struct SalientTermExtractorTests {
    @Test func identifiersAreSalient() {
        let terms = SalientTermExtractor.terms(from: [
            "run the parakeetBackend with user_id and build.sh today",
        ])
        #expect(terms.contains("parakeetBackend"))
        #expect(terms.contains("user_id"))
        #expect(terms.contains("build.sh"))
        #expect(!terms.contains("run"))
        #expect(!terms.contains("today"))
    }

    @Test func pascalCaseAndAllCapsAreSalient() {
        let terms = SalientTermExtractor.terms(from: ["WhisperKit exports JSON"])
        #expect(terms.contains("WhisperKit"))
        #expect(terms.contains("JSON"))
    }

    @Test func digitBearingTokensAreSalient() {
        let terms = SalientTermExtractor.terms(from: ["release v0.0.3 uses EOU120M"])
        #expect(terms.contains("v0.0.3"))
        #expect(terms.contains("EOU120M"))
    }

    @Test func pureNumbersAreNot() {
        #expect(SalientTermExtractor.terms(from: ["pay 12000 by 2026"]).isEmpty)
    }

    @Test func midSentenceCapitalsAreSalient_sentenceStartsAreNot() {
        let terms = SalientTermExtractor.terms(from: [
            "The report went to Marek. Later we shipped.",
        ])
        #expect(terms.contains("Marek"))
        #expect(!terms.contains("The"))
        #expect(!terms.contains("Later"))
    }

    @Test func newlineStartsASentence() {
        let terms = SalientTermExtractor.terms(from: ["first line\nSecond line"])
        #expect(!terms.contains("Second"))
    }

    @Test func trailingSentenceDotIsStripped_interiorDotIsKept() {
        let terms = SalientTermExtractor.terms(from: ["ask Marek. then run build.sh"])
        #expect(terms.contains("Marek"))
        #expect(terms.contains("build.sh"))
        #expect(!terms.contains("Marek."))
    }

    @Test func dedupeIsCaseInsensitive_firstCasingWins() {
        let terms = SalientTermExtractor.terms(from: [
            "WhisperKit is here", "we love whisperkit",
        ])
        #expect(terms.filter { $0.lowercased() == "whisperkit" } == ["WhisperKit"])
    }

    @Test func frequencyOrdersFirst_thenFirstSeen() {
        let terms = SalientTermExtractor.terms(from: [
            "Alpha1 then Beta2 then Beta2",
        ])
        #expect(terms == ["Beta2", "Alpha1"])
    }

    @Test func capLimitsOutput() {
        let text = (1...50).map { "Term\($0)x" }.joined(separator: " ")
        #expect(SalientTermExtractor.terms(from: [text]).count == 30)
        #expect(SalientTermExtractor.terms(from: [text], cap: 5).count == 5)
    }

    @Test func lengthBoundsRejectJunk() {
        let long = String(repeating: "ab", count: 30) // 60 chars
        let terms = SalientTermExtractor.terms(from: ["ab \(long) CamelCaseFine"])
        #expect(terms == ["CamelCaseFine"])
    }

    @Test func emptyInputIsEmpty() {
        #expect(SalientTermExtractor.terms(from: []).isEmpty)
        #expect(SalientTermExtractor.terms(from: ["", "   "]).isEmpty)
    }
}
