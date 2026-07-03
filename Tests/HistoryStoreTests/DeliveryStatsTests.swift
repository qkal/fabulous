import FabCore
import Foundation
import Testing

@testable import HistoryStore

@Suite struct DeliveryStatsTests {
    private func entry(
        method: DeliveryMethod?,
        deliveryMs: Double = 60,
        secondsAgo: TimeInterval = 0
    ) -> MetricsEntry {
        MetricsEntry(
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000_000 - secondsAgo),
            engineID: "large-v3_turbo",
            audioSeconds: 2,
            stopTrimMs: 40,
            asrMs: 900,
            postMs: 5,
            deliveryMs: deliveryMs,
            totalMs: 1005,
            deliveryMethod: method
        )
    }

    @Test func rawColumnPinsTheSchema() throws {
        let store = try HistoryStore.inMemory()
        try store.recordMetrics(entry(method: .paste, secondsAgo: 0))
        try store.recordMetrics(entry(method: nil, secondsAgo: 10))
        // Newest first: paste row, then the pre-migration-style NULL row.
        #expect(try store.rawDeliveryMethods() == ["paste", nil])
    }

    @Test func statsAggregatePerMethodAndExcludeNullRows() throws {
        let store = try HistoryStore.inMemory()
        try store.recordMetrics(entry(method: .axInsert, deliveryMs: 8, secondsAgo: 1))
        try store.recordMetrics(entry(method: .axInsert, deliveryMs: 10, secondsAgo: 2))
        try store.recordMetrics(entry(method: .paste, deliveryMs: 58, secondsAgo: 3))
        try store.recordMetrics(entry(method: .safetyNet, deliveryMs: 1, secondsAgo: 4))
        // Pre-migration row: excluded from counts entirely.
        try store.recordMetrics(entry(method: nil, deliveryMs: 999, secondsAgo: 5))

        let stats = try #require(try store.deliveryStats())
        #expect(stats.sampleCount == 4)
        // Fixed display order: axInsert, paste, keystrokes, safetyNet —
        // keystrokes has no rows and is omitted.
        #expect(stats.methods.map(\.method) == [.axInsert, .paste, .safetyNet])
        #expect(stats.methods[0].count == 2)
        #expect(stats.methods[0].p50DeliveryMs == 8)  // nearest-rank p50 of [8, 10]
        #expect(stats.methods[1].count == 1)
        #expect(stats.methods[1].p50DeliveryMs == 58)
    }

    @Test func statsAreNilWithoutQualifyingRows() throws {
        let store = try HistoryStore.inMemory()
        #expect(try store.deliveryStats() == nil)
        try store.recordMetrics(entry(method: nil))
        #expect(try store.deliveryStats() == nil)
    }

    @Test func menuSummaryFormatsSharesAndP50s() {
        let stats = DeliveryStats(
            sampleCount: 100,
            methods: [
                .init(method: .axInsert, count: 60, p50DeliveryMs: 8),
                .init(method: .paste, count: 29, p50DeliveryMs: 58),
                .init(method: .keystrokes, count: 8, p50DeliveryMs: 210),
                .init(method: .safetyNet, count: 3, p50DeliveryMs: 1),
            ]
        )
        #expect(stats.menuSummary
            == "Inject ax 60% 8 ms · paste 29% 58 ms · keys 8% 210 ms · net 3%")
    }

    @Test func menuSummaryOmitsP50ForSafetyNetOnly() {
        let stats = DeliveryStats(
            sampleCount: 2,
            methods: [.init(method: .safetyNet, count: 2, p50DeliveryMs: 1)]
        )
        #expect(stats.menuSummary == "Inject net 100%")
    }
}
