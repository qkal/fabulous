import FabCore
import Testing

@Suite("DictationMetrics")
struct DictationMetricsTests {
    private let metrics = DictationMetrics(
        audioDuration: 10.4,
        stopAndTrim: .milliseconds(80),
        transcription: .milliseconds(1020),
        postProcessing: .milliseconds(3),
        delivery: .milliseconds(180),
        total: .milliseconds(1283)
    )

    @Test func menuSummaryLeadsWithFeltLatency() {
        #expect(metrics.menuSummary == "Last: 1.28 s · ASR 1.02 s · 10.4 s audio")
    }

    @Test func logLineContainsEveryStage() {
        let line = metrics.logLine
        #expect(line.contains("total=1.28 s"))
        #expect(line.contains("stop+vad=0.08 s"))
        #expect(line.contains("asr=1.02 s"))
        #expect(line.contains("post=0.00 s"))
        #expect(line.contains("delivery=0.18 s"))
        #expect(line.contains("audio=10.40s"))
    }

    @Test func budgetCheckUsesTotal() {
        #expect(!metrics.exceedsBudget())
        var slow = metrics
        slow.total = .milliseconds(1600)
        #expect(slow.exceedsBudget())
        #expect(!slow.exceedsBudget(2.0))
    }
}
