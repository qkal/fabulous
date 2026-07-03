import Foundation
import Testing

@testable import HistoryStore

@Suite("HistoryStore")
struct HistoryStoreTests {
    @Test func recordAndFetchNewestFirst() throws {
        let store = try HistoryStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_000_000)
        try store.record(text: "first", audioSeconds: 1, modelID: "base", cap: 10, date: base)
        try store.record(
            text: "second", audioSeconds: 2, modelID: "base", cap: 10,
            date: base.addingTimeInterval(60)
        )

        let recent = try store.recent(limit: 10)
        #expect(recent.map(\.text) == ["second", "first"])
        #expect(recent[0].audioSeconds == 2)
        #expect(recent[0].modelID == "base")
    }

    @Test func capPrunesOldestEntries() throws {
        let store = try HistoryStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<8 {
            try store.record(
                text: "entry \(i)", audioSeconds: 1, modelID: "base", cap: 5,
                date: base.addingTimeInterval(Double(i))
            )
        }
        #expect(try store.count() == 5)
        let texts = try store.recent(limit: 10).map(\.text)
        #expect(texts == ["entry 7", "entry 6", "entry 5", "entry 4", "entry 3"])
    }

    @Test func clearEmptiesTheTable() throws {
        let store = try HistoryStore.inMemory()
        try store.record(text: "x", audioSeconds: 1, modelID: "base", cap: 10)
        try store.clear()
        #expect(try store.count() == 0)
        #expect(try store.recent(limit: 10).isEmpty)
    }

    @Test func limitCapsRecentResults() throws {
        let store = try HistoryStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<5 {
            try store.record(
                text: "entry \(i)", audioSeconds: 1, modelID: "base", cap: 100,
                date: base.addingTimeInterval(Double(i))
            )
        }
        #expect(try store.recent(limit: 2).count == 2)
    }

    @Test func persistsAcrossReopen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fabulous-tests-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("history.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try HistoryStore(url: url)
        try store.record(text: "durable", audioSeconds: 1, modelID: "base", cap: 10)

        let reopened = try HistoryStore(url: url)
        #expect(try reopened.recent(limit: 1).first?.text == "durable")
    }

    // MARK: - Dictation metrics

    private func metricsEntry(
        engineID: String,
        totalMs: Double,
        asrMs: Double = 0,
        date: Date
    ) -> MetricsEntry {
        MetricsEntry(
            createdAt: date, engineID: engineID, audioSeconds: 10,
            stopTrimMs: 5, asrMs: asrMs, postMs: 1, deliveryMs: 30, totalMs: totalMs
        )
    }

    @Test func latencyStatsComputePercentilesPerEngine() throws {
        let store = try HistoryStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_000_000)
        // Ten whisper runs at 100…1000 ms, and one apple-speech outlier that
        // must not leak into whisper's stats.
        for i in 1...10 {
            try store.recordMetrics(metricsEntry(
                engineID: "whisper", totalMs: Double(i) * 100, asrMs: Double(i) * 80,
                date: base.addingTimeInterval(Double(i))
            ))
        }
        try store.recordMetrics(metricsEntry(
            engineID: "apple-speech", totalMs: 9999, date: base.addingTimeInterval(60)
        ))

        let whisper = try #require(try store.latencyStats(engineID: "whisper"))
        #expect(whisper.sampleCount == 10)
        #expect(whisper.p50TotalMs == 500) // nearest-rank: 5th of 10
        #expect(whisper.p90TotalMs == 900)
        #expect(whisper.p50ASRMs == 400)
        #expect(whisper.p90ASRMs == 720)

        let apple = try #require(try store.latencyStats(engineID: "apple-speech"))
        #expect(apple.sampleCount == 1)
        #expect(apple.p50TotalMs == 9999)
        #expect(apple.p90TotalMs == 9999)
    }

    @Test func latencyStatsAreNilWithoutSamples() throws {
        let store = try HistoryStore.inMemory()
        #expect(try store.latencyStats(engineID: "whisper") == nil)
    }

    @Test func metricsCapPrunesOldestRows() throws {
        let store = try HistoryStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<8 {
            try store.recordMetrics(
                metricsEntry(
                    engineID: "whisper", totalMs: Double(i),
                    date: base.addingTimeInterval(Double(i))
                ),
                cap: 5
            )
        }
        let stats = try #require(try store.latencyStats(engineID: "whisper"))
        #expect(stats.sampleCount == 5)
        // The survivors are the newest five (totals 3…7).
        #expect(stats.p90TotalMs == 7)
    }

    @Test func clearingTranscriptsKeepsMetrics() throws {
        let store = try HistoryStore.inMemory()
        try store.record(text: "secret", audioSeconds: 1, modelID: "whisper", cap: 10)
        try store.recordMetrics(metricsEntry(engineID: "whisper", totalMs: 100, date: Date()))

        try store.clear()
        #expect(try store.count() == 0)
        #expect(try store.latencyStats(engineID: "whisper")?.sampleCount == 1)
    }

    @Test func percentileUsesNearestRank() {
        #expect(HistoryStore.percentile([10], 0.5) == 10)
        #expect(HistoryStore.percentile([10, 20], 0.5) == 10)
        #expect(HistoryStore.percentile([10, 20], 0.9) == 20)
        #expect(HistoryStore.percentile([10, 20, 30, 40], 0.5) == 20)
    }

    @Test func recordStoresRawTextWhenProvided() throws {
        let store = try HistoryStore.inMemory()
        try store.record(
            text: "Ship it.", rawText: "um ship it",
            audioSeconds: 1.2, modelID: "test", cap: 10
        )
        let entries = try store.recent()
        #expect(entries.first?.text == "Ship it.")
        #expect(entries.first?.rawText == "um ship it")
    }

    @Test func rawTextDefaultsToNil() throws {
        let store = try HistoryStore.inMemory()
        try store.record(text: "hello", audioSeconds: 1, modelID: "test", cap: 10)
        #expect(try store.recent().first?.rawText == nil)
    }
}
