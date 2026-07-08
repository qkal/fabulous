import FabCore
import Foundation
import HistoryStore
import Testing

@Suite("Cleanup stats")
struct CleanupStatsTests {
    private func entry(
        llmMs: Double, llmOutcome: LLMCleanupOutcome, at date: Date
    ) -> MetricsEntry {
        MetricsEntry(
            createdAt: date,
            engineID: "large-v3_turbo",
            audioSeconds: 5,
            stopTrimMs: 50,
            asrMs: 900,
            postMs: 2,
            deliveryMs: 150,
            totalMs: 1500,
            llmMs: llmMs,
            llmOutcome: llmOutcome
        )
    }

    @Test func nilWhenNoLLMRows() throws {
        let store = try HistoryStore.inMemory()
        try store.recordMetrics(entry(llmMs: 0, llmOutcome: .off, at: Date()))
        #expect(try store.cleanupStats() == nil)
    }

    @Test func excludesOffRowsAndCountsFallbacks() throws {
        let store = try HistoryStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_000_000)
        try store.recordMetrics(entry(llmMs: 0, llmOutcome: .off, at: base))
        try store.recordMetrics(entry(llmMs: 300, llmOutcome: .changed, at: base.addingTimeInterval(1)))
        try store.recordMetrics(entry(llmMs: 500, llmOutcome: .unchanged, at: base.addingTimeInterval(2)))
        try store.recordMetrics(entry(llmMs: 700, llmOutcome: .fellBack, at: base.addingTimeInterval(3)))

        let stats = try #require(try store.cleanupStats())
        #expect(stats.sampleCount == 3)
        #expect(stats.fellBackCount == 1)
        #expect(stats.p50LlmMs == 500)
        #expect(stats.p90LlmMs == 700)
    }

    @Test func limitBoundsTheWindow() throws {
        let store = try HistoryStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<4 {
            try store.recordMetrics(entry(
                llmMs: Double(100 * (i + 1)), llmOutcome: .changed,
                at: base.addingTimeInterval(Double(i))
            ))
        }
        // Newest 2 rows only: 300 and 400 ms.
        let stats = try #require(try store.cleanupStats(limit: 2))
        #expect(stats.sampleCount == 2)
        #expect(stats.p50LlmMs == 300)
    }

    @Test func menuSummaryFormat() {
        let stats = CleanupStats(
            sampleCount: 41, p50LlmMs: 380, p90LlmMs: 710, fellBackCount: 2, rejectedCount: 0
        )
        #expect(stats.menuSummary == "Cleanup p50 0.38 s · p90 0.71 s · fell back 2/41 · rejected 0/41")
    }

    @Test func outcomePersistsAsRawValueText() throws {
        // The column is TEXT holding the enum raw value — pinned so a case
        // rename can't silently corrupt old rows.
        let store = try HistoryStore.inMemory()
        try store.recordMetrics(entry(llmMs: 1, llmOutcome: .fellBack, at: Date()))
        let raw = try store.rawLLMOutcomes()
        #expect(raw == ["fellBack"])
    }

    @Test func oldRowsReadBackAsOff() throws {
        // Rows inserted before v5 (simulated via default params) must read
        // back as off/0 — the migration defaults.
        let store = try HistoryStore.inMemory()
        try store.recordMetrics(MetricsEntry(
            createdAt: Date(), engineID: "e", audioSeconds: 1,
            stopTrimMs: 1, asrMs: 1, postMs: 1, deliveryMs: 1, totalMs: 5
        ))
        let stats = try store.cleanupStats()
        #expect(stats == nil)
    }

    @Test func cleanupStatsCountsRejectedRows() throws {
        let store = try HistoryStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_000_000)
        try store.recordMetrics(entry(llmMs: 250, llmOutcome: .rejected, at: base))
        try store.recordMetrics(entry(llmMs: 700, llmOutcome: .fellBack, at: base.addingTimeInterval(1)))
        try store.recordMetrics(entry(llmMs: 500, llmOutcome: .changed, at: base.addingTimeInterval(2)))
        let stats = try #require(try store.cleanupStats())
        #expect(stats.rejectedCount == 1)
        #expect(stats.fellBackCount == 1)
    }

    @Test func cleanupMenuSummaryShowsRejected() {
        let stats = CleanupStats(
            sampleCount: 41, p50LlmMs: 380, p90LlmMs: 710,
            fellBackCount: 2, rejectedCount: 1
        )
        #expect(stats.menuSummary == "Cleanup p50 0.38 s · p90 0.71 s · fell back 2/41 · rejected 1/41")
    }
}
