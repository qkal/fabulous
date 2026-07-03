import Foundation
import PostProcessing
import Testing

/// Exercises the real on-device model. Opt-in: FAB_REAL_LLM=1 swift test
/// --filter RealFoundationModelTests. Gating mirrors FAB_REAL_ASR in
/// SpeechAnalyzerBackendTests: per-test `.enabled(if:)`, since Swift
/// Testing has no runtime skip-from-inside-a-test. The flag alone isn't
/// enough here — the suite also needs Apple Intelligence actually on, so
/// the trait additionally checks PostProcessingAvailability.current; a
/// machine with the flag set but Apple Intelligence off skips instead of
/// failing.
@Suite struct RealFoundationModelTests {
    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["FAB_REAL_LLM"] == "1"
            && PostProcessingAvailability.current == .available
    }

    private struct UnsupportedOS: Error {}

    private func makeProcessor(vocabulary: [String] = []) throws -> FoundationModelPostProcessor {
        // Unreachable when the trait passed (availability implies macOS
        // 26), but the compiler still needs the #available gate.
        guard #available(macOS 26.0, *) else { throw UnsupportedOS() }
        return FoundationModelPostProcessor(
            requester: FoundationModelRequester(),
            vocabulary: vocabulary,
            timeout: .seconds(30)
        )
    }

    @Test(.enabled(if: RealFoundationModelTests.isEnabled))
    func removesFillerWords() async throws {
        let processor = try makeProcessor()
        let result = try await processor.process("um so I think we should uh ship it")
        #expect(!result.lowercased().contains("um"))
        #expect(!result.lowercased().contains(" uh "))
        #expect(result.lowercased().contains("ship it"))
    }

    @Test(.enabled(if: RealFoundationModelTests.isEnabled))
    func newParagraphBecomesBlankLine() async throws {
        let processor = try makeProcessor()
        let result = try await processor.process("first point new paragraph second point")
        #expect(result.contains("\n"))
        #expect(!result.lowercased().contains("new paragraph"))
    }

    @Test(.enabled(if: RealFoundationModelTests.isEnabled))
    func scratchThatDropsPrecedingClause() async throws {
        let processor = try makeProcessor()
        let result = try await processor.process(
            "send it tomorrow scratch that send it on Friday"
        )
        #expect(!result.lowercased().contains("scratch"))
        #expect(result.lowercased().contains("friday"))
        #expect(!result.lowercased().contains("tomorrow"))
    }

    @Test(.enabled(if: RealFoundationModelTests.isEnabled))
    func vocabularyBiasesSpelling() async throws {
        let processor = try makeProcessor(vocabulary: ["WhisperKit"])
        let result = try await processor.process("we integrated whisper kit last week")
        #expect(result.contains("WhisperKit"))
    }

    @Test(.enabled(if: RealFoundationModelTests.isEnabled))
    func commandWordsAsContentSurvive() async throws {
        let processor = try makeProcessor()
        let result = try await processor.process("I applied for a new line of credit")
        #expect(result.lowercased().contains("new line of credit"))
    }
}
