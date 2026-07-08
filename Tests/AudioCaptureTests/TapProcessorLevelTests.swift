import AVFoundation
import Testing
@testable import AudioCapture

@Suite("TapProcessor level decay")
struct TapProcessorLevelTests {
    @Test func levelDecaysToZeroAfterStall() {
        let p = TapProcessor(targetSampleRate: 16_000)
        // Simulate a processed buffer whose timestamp is well in the past.
        p.setLastProcessedForTest(monotonicSecondsAgo: 1.0, rms: 0.5)
        #expect(p.level == 0)
    }

    @Test func levelReportsRecentRMS() {
        let p = TapProcessor(targetSampleRate: 16_000)
        p.setLastProcessedForTest(monotonicSecondsAgo: 0.0, rms: 0.5)
        #expect(p.level > 0)
    }
}
