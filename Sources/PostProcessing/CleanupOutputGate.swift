import Foundation

/// Accept/reject filter for LLM cleanup output. Pure — no FoundationModels
/// import, fully unit-testable.
///
/// Rationale: legitimate cleanup only *removes* words (fillers, scratch-
/// that), fixes punctuation/casing, and substitutes few words (homophones,
/// vocabulary spellings). Hallucination *invents* words. So: tokenize both
/// texts, count cleaned tokens without a matching raw occurrence left to
/// consume (frequency-aware — a repetition flood of one raw word is still
/// invented content), and reject when too much of the output is novel — or
/// when the output grew beyond what "never add content" allows.
///
/// Tokenization is whitespace-based; non-spaced scripts (CJK) degrade to
/// always-reject, which is safe (cleanup no-ops, raw text is delivered) and
/// accepted for now.
public enum CleanupOutputGate {
    /// Above this share of (uncredited) novel tokens, the output is a
    /// rewrite, not a cleanup. Pinned by CleanupOutputGateTests — change
    /// the corpus before changing the number.
    static let maxNovelRatio = 0.3

    public static func permits(raw: String, cleaned: String, vocabulary: [String]) -> Bool {
        let rawTokens = tokens(raw)
        let cleanedTokens = tokens(cleaned)
        guard !cleanedTokens.isEmpty else { return true }  // empty handled upstream

        // "Never add content", mechanically: absolute slack keeps tiny
        // utterances ("hi" -> "Hi.") from tripping a bare ratio.
        if cleanedTokens.count > rawTokens.count * 3 / 2 + 3 { return false }

        // Multiset, not set: each cleaned token consumes one raw occurrence.
        // A cleaned token whose raw count is exhausted (or never present) is
        // novel — catches repetition floods that reuse a single raw word.
        var rawCounts: [String: Int] = [:]
        for token in rawTokens { rawCounts[token, default: 0] += 1 }
        let vocabSet = Set(vocabulary.flatMap { tokens($0) })
        var novel = 0
        var vocabNovel = 0
        for token in cleanedTokens {
            if let remaining = rawCounts[token], remaining > 0 {
                rawCounts[token] = remaining - 1
            } else if vocabSet.contains(token) {
                vocabNovel += 1
            } else {
                novel += 1
            }
        }
        // Vocabulary substitution is the one sanctioned source of new words,
        // but uncapped credit would wave through a hallucination composed of
        // screen terms — cap it.
        let vocabCredit = min(vocabNovel, max(2, cleanedTokens.count / 10))
        let effectiveNovel = novel + (vocabNovel - vocabCredit)
        return Double(effectiveNovel) / Double(cleanedTokens.count) <= maxNovelRatio
    }

    /// Lowercased words with edge punctuation stripped; interior
    /// apostrophes/hyphens survive ("they're", "day-to-day").
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }
}
