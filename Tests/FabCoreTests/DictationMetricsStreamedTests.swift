import Foundation
import Testing

@testable import FabCore

@Suite struct DictationMetricsStreamedTests {
    private func metrics(streamed: Bool) -> DictationMetrics {
        DictationMetrics(
            audioDuration: 2.0,
            stopAndTrim: .milliseconds(20),
            transcription: .milliseconds(300),
            postProcessing: .milliseconds(1),
            delivery: .milliseconds(30),
            total: .milliseconds(351),
            streamed: streamed
        )
    }

    @Test func streamedDefaultsToFalse() {
        let m = DictationMetrics(
            audioDuration: 1, stopAndTrim: .zero, transcription: .zero,
            postProcessing: .zero, delivery: .zero, total: .zero
        )
        #expect(m.streamed == false)
    }

    @Test func logLineMarksStreamedDictations() {
        #expect(metrics(streamed: true).logLine.contains(" streamed"))
        #expect(!metrics(streamed: false).logLine.contains("streamed"))
    }
}
