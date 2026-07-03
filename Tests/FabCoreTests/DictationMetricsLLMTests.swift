import FabCore
import Testing

@Suite("DictationMetrics LLM stage")
struct DictationMetricsLLMTests {
    private func metrics(
        llmCleanup: Duration = .zero,
        llmOutcome: LLMCleanupOutcome = .off
    ) -> DictationMetrics {
        DictationMetrics(
            audioDuration: 10.4,
            stopAndTrim: .milliseconds(80),
            transcription: .milliseconds(1020),
            llmCleanup: llmCleanup,
            llmOutcome: llmOutcome,
            postProcessing: .milliseconds(3),
            delivery: .milliseconds(180),
            total: .milliseconds(1283)
        )
    }

    @Test func defaultsAreOffAndZero() {
        // Existing callers omit the new params: outcome off, duration zero.
        let m = DictationMetrics(
            audioDuration: 1,
            stopAndTrim: .zero,
            transcription: .zero,
            postProcessing: .zero,
            delivery: .zero,
            total: .zero
        )
        #expect(m.llmOutcome == .off)
        #expect(m.llmCleanup == .zero)
    }

    @Test func logLineOmitsLLMWhenOff() {
        #expect(!metrics().logLine.contains("llm="))
    }

    @Test func logLineShowsLLMStageWhenActive() {
        let line = metrics(
            llmCleanup: .milliseconds(420), llmOutcome: .changed
        ).logLine
        #expect(line.contains("llm=0.42 s (changed)"))
    }

    @Test func rawValuesAreStableForPersistence() {
        // These strings land in SQLite; renaming a case is a schema change.
        #expect(LLMCleanupOutcome.off.rawValue == "off")
        #expect(LLMCleanupOutcome.unchanged.rawValue == "unchanged")
        #expect(LLMCleanupOutcome.changed.rawValue == "changed")
        #expect(LLMCleanupOutcome.fellBack.rawValue == "fellBack")
    }
}
