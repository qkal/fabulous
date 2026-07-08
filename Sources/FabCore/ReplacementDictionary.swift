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

    /// Immutable after construction; `NSRegularExpression` is documented
    /// thread-safe for matching, so sharing the compiled rules is safe.
    private final class CompiledRules: @unchecked Sendable {
        let items: [(regex: NSRegularExpression, template: String)]
        init(items: [(regex: NSRegularExpression, template: String)]) {
            self.items = items
        }
    }

    public var entries: [Entry] {
        didSet { compiled = Self.compile(entries) }
    }

    private var compiled: CompiledRules

    public init(entries: [Entry] = []) {
        self.entries = entries
        self.compiled = Self.compile(entries)
    }

    public func process(_ text: String) async throws -> String {
        apply(to: text)
    }

    /// Synchronous core, exposed for tests.
    public func apply(to text: String) -> String {
        var result = text
        for item in compiled.items {
            result = item.regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: item.template
            )
        }
        return result
    }

    /// Compiles `entries` into ready-to-match regexes, skipping empty
    /// patterns and any pattern that fails to compile. Called once at
    /// construction and again whenever `entries` is replaced wholesale.
    private static func compile(_ entries: [Entry]) -> CompiledRules {
        let items: [(regex: NSRegularExpression, template: String)] = entries.compactMap { entry in
            guard !entry.pattern.isEmpty else { return nil }
            let escaped = NSRegularExpression.escapedPattern(for: entry.pattern)
            var options: NSRegularExpression.Options = []
            if !entry.caseSensitive {
                options.insert(.caseInsensitive)
            }
            // Lookarounds instead of \b: a trailing \b never matches after a
            // non-word character, which would break patterns like "c++".
            guard let regex = try? NSRegularExpression(
                pattern: "(?<!\\w)\(escaped)(?!\\w)", options: options
            ) else { return nil }
            return (regex, NSRegularExpression.escapedTemplate(for: entry.replacement))
        }
        return CompiledRules(items: items)
    }
}
