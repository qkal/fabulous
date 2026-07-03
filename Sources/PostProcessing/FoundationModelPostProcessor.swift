import FabCore
import Foundation

/// A post-processor whose prompt depends on per-dictation context
/// (the injection target app). AppController sets the context right
/// before running the pipeline.
public protocol ContextualTextPostProcessor: TextPostProcessor {
    func setAppContext(name: String?) async
}

/// Seam over the language model so fallback behavior is testable
/// without Apple Intelligence.
public protocol LanguageModelRequesting: Sendable {
    func cleanup(instructions: String, transcript: String) async throws -> String
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

    public func process(_ text: String) async throws -> String {
        guard !text.isEmpty else { return text }
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
                return Self.endsWithScratchThat(text) ? "" : text
            }
            return cleaned
        } catch {
            NSLog("fabulous: LLM cleanup failed, using raw transcript: \(error)")
            return text
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
