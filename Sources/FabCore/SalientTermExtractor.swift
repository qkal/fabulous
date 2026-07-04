import Foundation

/// Distills harvested screen text into the terms worth biasing dictation
/// with — identifiers, proper nouns, digit-bearing tokens — instead of a
/// raw dump that would blow the cleanup model's small context. Pure;
/// tests pin the heuristics. Heuristics only in v1 (no dictionary lookup:
/// NSSpellChecker is AppKit and FabCore stays AppKit-free).
public enum SalientTermExtractor {
    public static let defaultCap = 30

    /// Token length bounds: shorter is noise ("ab"), longer is minified
    /// junk or base64.
    private static let lengthRange = 3...40

    public static func terms(from texts: [String], cap: Int = defaultCap) -> [String] {
        var order: [String] = []          // first-seen order of lowercased keys
        var counts: [String: Int] = [:]
        var casing: [String: String] = [:] // first-seen original casing

        for text in texts {
            for (token, startsSentence) in rawTokens(in: text) {
                guard isSalient(token, midSentence: !startsSentence) else { continue }
                let key = token.lowercased()
                if counts[key] == nil {
                    order.append(key)
                    casing[key] = token
                }
                counts[key, default: 0] += 1
            }
        }

        return order.enumerated()
            .sorted { lhs, rhs in
                let (lc, rc) = (counts[lhs.element] ?? 0, counts[rhs.element] ?? 0)
                return lc == rc ? lhs.offset < rhs.offset : lc > rc
            }
            .prefix(cap)
            .compactMap { casing[$0.element] }
    }

    /// Tokens are runs of [letters, digits, "_", "."], so "build.sh" and
    /// "user_id" survive as single tokens. Edge dots are trimmed — a
    /// trailing "." is a sentence terminator, and the NEXT token starts a
    /// sentence; "!", "?", and newlines do the same from between tokens.
    static func rawTokens(in text: String) -> [(token: String, startsSentence: Bool)] {
        var result: [(String, Bool)] = []
        var current = ""
        var nextStartsSentence = true

        func flush() {
            guard !current.isEmpty else { return }
            let hadTrailingDot = current.hasSuffix(".")
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !trimmed.isEmpty {
                result.append((trimmed, nextStartsSentence))
                nextStartsSentence = hadTrailingDot
            }
            current = ""
        }

        for character in text {
            if character.isLetter || character.isNumber || character == "_" || character == "." {
                current.append(character)
            } else {
                flush()
                if character == "!" || character == "?" || character == "\n" {
                    nextStartsSentence = true
                }
            }
        }
        flush()
        return result
    }

    static func isSalient(_ token: String, midSentence: Bool) -> Bool {
        guard lengthRange.contains(token.count) else { return false }
        guard token.contains(where: \.isLetter) else { return false } // no pure numbers

        let hasDigit = token.contains(where: \.isNumber)
        let hasUnderscore = token.contains("_")
        let hasInteriorDot = token.dropFirst().dropLast().contains(".")
        let letters = token.filter(\.isLetter)
        let hasUpper = letters.contains(where: \.isUppercase)
        let hasLower = letters.contains(where: \.isLowercase)
        let upperAfterFirst = token.dropFirst().contains(where: \.isUppercase)

        let isCamelOrPascal = hasLower && upperAfterFirst        // parakeetBackend, WhisperKit
        let isAllCaps = hasUpper && !hasLower && token.count <= 10 // JSON, EOU, TDT
        if hasDigit || hasUnderscore || hasInteriorDot || isCamelOrPascal || isAllCaps {
            return true
        }
        // Plain Capitalized word: a proper noun only when not opening a
        // sentence — "Marek said" vs "The report".
        let isCapitalized = token.first?.isUppercase == true && hasLower && !upperAfterFirst
        return isCapitalized && midSentence
    }
}
