import Foundation

/// User-configured text replacements, e.g. "anthropite" → "Anthropite".
///
/// Matches whole words only (so "anthropites" is left alone) and is
/// case-insensitive by default, which is what you want for ASR output —
/// Whisper capitalizes unpredictably.
public struct ReplacementDictionary: TextPostProcessor {
    public struct Entry: Sendable, Equatable, Codable {
        public var pattern: String
        public var replacement: String
        public var caseSensitive: Bool

        public init(pattern: String, replacement: String, caseSensitive: Bool = false) {
            self.pattern = pattern
            self.replacement = replacement
            self.caseSensitive = caseSensitive
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public func process(_ text: String) async throws -> String {
        apply(to: text)
    }

    /// Synchronous core, exposed for tests.
    public func apply(to text: String) -> String {
        var result = text
        for entry in entries where !entry.pattern.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: entry.pattern)
            var options: NSRegularExpression.Options = []
            if !entry.caseSensitive {
                options.insert(.caseInsensitive)
            }
            // Lookarounds instead of \b: a trailing \b never matches after a
            // non-word character, which would break patterns like "c++".
            guard let regex = try? NSRegularExpression(
                pattern: "(?<!\\w)\(escaped)(?!\\w)", options: options
            ) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: entry.replacement)
            )
        }
        return result
    }
}
