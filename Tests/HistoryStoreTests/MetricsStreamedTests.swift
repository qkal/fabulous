import Foundation
import Testing

@testable import HistoryStore

@Suite struct MetricsStreamedTests {
    private func entry(streamed: Bool) -> MetricsEntry {
        MetricsEntry(
            createdAt: Date(),
            engineID: "apple-speech",
            audioSeconds: 2.0,
            stopTrimMs: 20,
            asrMs: 300,
            postMs: 1,
            deliveryMs: 30,
            totalMs: 351,
            streamed: streamed
        )
    }

    @Test func streamedRoundTrips() throws {
        let store = try HistoryStore.inMemory()
        try store.recordMetrics(entry(streamed: true))
        try store.recordMetrics(entry(streamed: false))
        let stats = try store.latencyStats(engineID: "apple-speech")
        #expect(stats?.sampleCount == 2)
    }

    @Test func streamedDefaultsToFalse() {
        let e = MetricsEntry(
            createdAt: Date(), engineID: "x", audioSeconds: 1,
            stopTrimMs: 1, asrMs: 1, postMs: 1, deliveryMs: 1, totalMs: 4
        )
        #expect(e.streamed == false)
    }
}
