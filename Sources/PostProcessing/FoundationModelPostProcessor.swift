import FabCore
import Foundation

/// What the cleanup stage produced and what it did — the outcome feeds
/// DictationMetrics so fallbacks are distinguishable from no-ops.
public struct CleanupReport: Sendable, Equatable {
    public let text: String
    public let outcome: LLMCleanupOutcome

    public init(text: String, outcome: LLMCleanupOutcome) {
        self.text = text
        self.outcome = outcome
    }
}

/// A post-processor whose prompt depends on per-dictation context
/// (the injection target app). AppController sets the context right
/// before running the pipeline.
public protocol ContextualTextPostProcessor: TextPostProcessor {
    func setAppContext(name: String?) async
    /// Non-throwing cleanup with outcome reporting. Implementations must
    /// uphold the invariant: every failure returns the input text.
    func cleanup(_ text: String) async -> CleanupReport
    /// Optional prewarm hook, called at record-start so model warm-up
    /// overlaps the user speaking.
    func prepare() async
}

extension ContextualTextPostProcessor {
    public func prepare() async {}
}

/// Seam over the language model so fallback behavior is testable
/// without Apple Intelligence.
public protocol LanguageModelRequesting: Sendable {
    func cleanup(instructions: String, transcript: String) async throws -> String
    /// Optional prewarm hook: build/warm a session for these instructions
    /// ahead of the cleanup call. Best-effort — failures must be swallowed.
    func prepare(instructions: String) async
}

extension LanguageModelRequesting {
    public func prepare(instructions: String) async {}
}

/// LLM cleanup stage. Invariant: may improve or no-op, never lose text —
/// every failure path returns the raw transcript unchanged.
public actor FoundationModelPostProcessor: ContextualTextPostProcessor {
    private let requester: any LanguageModelRequesting
    private let vocabulary: [String]
    private let timeout: Duration
    private var appName: String?

    public init(
        requester: any LanguageModelRequesting,
        vocabulary: [String],
        timeout: Duration = .seconds(3)
    ) {
        self.requester = requester
        self.vocabulary = vocabulary
        self.timeout = timeout
    }

    public func setAppContext(name: String?) {
        appName = name
    }

    public func prepare() async {
        // Must assemble the instructions EXACTLY as cleanup() does — the
        // requester only uses the warmed session on an exact match.
        let instructions = CleanupPromptBuilder.instructions(
            vocabulary: vocabulary, appName: appName
        )
        await requester.prepare(instructions: instructions)
    }

    public func process(_ text: String) async throws -> String {
        await cleanup(text).text
    }

    public func cleanup(_ text: String) async -> CleanupReport {
        // .off, not .unchanged: the model never ran, and "unchanged" is the
        // echo signal in dogfood stats.
        guard !text.isEmpty else {
            return CleanupReport(text: text, outcome: .off)
        }
        let instructions = CleanupPromptBuilder.instructions(
            vocabulary: vocabulary, appName: appName
        )
        do {
            let cleaned = try await Self.withTimeout(timeout) { [requester] in
                try await requester.cleanup(instructions: instructions, transcript: text)
            }
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // "blah blah scratch that" legitimately cleans to nothing;
                // empty output on anything else is a model failure.
                return Self.endsWithScratchThat(text)
                    ? CleanupReport(text: "", outcome: .changed)
                    : CleanupReport(text: text, outcome: .fellBack)
            }
            let stripped = Self.strippingEdgeSpaces(cleaned)
            return CleanupReport(
                text: stripped,
                outcome: stripped == text ? .unchanged : .changed
            )
        } catch {
            NSLog("fabulous: LLM cleanup failed, using raw transcript: \(error)")
            return CleanupReport(text: text, outcome: .fellBack)
        }
    }

    /// The only command that can legitimately empty an utterance — and only
    /// when it trails the content it cancels. Mid-utterance "scratch that"
    /// is content ("scratch that section off the list"), so empty output
    /// there is a model failure, not a cancellation. Trailing punctuation
    /// is tolerated because ASR likes to append it ("scratch that.").
    public static func endsWithScratchThat(_ text: String) -> Bool {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .hasSuffix("scratch that")
    }

    /// Drops stray spaces/tabs the model wraps around its reply, but keeps
    /// edge newlines: an utterance starting or ending with "new line"/
    /// "new paragraph" legitimately produces them, and injecting them is
    /// the point.
    static func strippingEdgeSpaces(_ text: String) -> String {
        var out = text
        while let first = out.first, first == " " || first == "\t" {
            out.removeFirst()
        }
        while let last = out.last, last == " " || last == "\t" {
            out.removeLast()
        }
        return out
    }

    private struct TimeoutError: Error {}

    private static func withTimeout<T: Sendable>(
        _ limit: Duration,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw TimeoutError()
            }
            guard let first = try await group.next() else { throw TimeoutError() }
            group.cancelAll()
            return first
        }
    }
}
