import FabCore
import Foundation
import PostProcessing
import ScreenReader
import Testing

/// Capture → extraction → cleanup-prompt flow with a fake reader — the
/// cross-module contract AppController relies on, minus AppController
/// itself (executable targets can't be imported by tests).
@Suite struct ScreenContextFlowTests {
    struct FakeReader: ScreenContextReading {
        let context: ScreenContext
        func read(pid: pid_t) async -> ScreenContext { context }
    }

    /// Records the instructions each call received.
    actor RecordingRequester: LanguageModelRequesting {
        private(set) var cleanupInstructions: [String] = []
        func cleanup(instructions: String, transcript: String) async throws -> String {
            cleanupInstructions.append(instructions)
            return transcript
        }
        func lastInstructions() -> String? { cleanupInstructions.last }
    }

    @Test func harvestedTermsReachTheCleanupPrompt() async {
        let reader = FakeReader(context: ScreenContext(
            windowTitle: "notes.md",
            terms: SalientTermExtractor.terms(from: ["deploy ParakeetTDT via build.sh"]),
            capturedAt: .distantPast
        ))
        let context = await reader.read(pid: 1)
        #expect(context.terms.contains("ParakeetTDT"))

        let requester = RecordingRequester()
        let processor = FoundationModelPostProcessor(requester: requester, vocabulary: ["Kal"])
        await processor.setScreenTerms(context.terms)
        _ = await processor.cleanup("we deploy parakeet tdt")

        let instructions = await requester.lastInstructions()
        #expect(instructions?.contains("ParakeetTDT") == true)
        #expect(instructions?.contains("Kal") == true)
    }

    @Test func slowReaderTimesOutAndDictationProceedsContextless() async {
        let task = Task<ScreenContext, Never> {
            try? await Task.sleep(for: .seconds(5))
            return ScreenContext(windowTitle: nil, terms: ["late"], capturedAt: .distantPast)
        }
        let context = await TaskTimeout.value(of: task, within: .milliseconds(20))
        #expect(context == nil)   // AppController maps nil to [] and proceeds
        task.cancel()
    }

    @Test func policyGatesTheWalk() {
        #expect(!ScreenContextPolicy.shouldCapture(enabled: false, cleanupOn: true, engineBiases: true))
        #expect(!ScreenContextPolicy.shouldCapture(enabled: true, cleanupOn: false, engineBiases: false))
        #expect(ScreenContextPolicy.shouldCapture(enabled: true, cleanupOn: true, engineBiases: false))
    }
}
