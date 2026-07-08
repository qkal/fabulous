import FabCore
import Testing

@Suite("CaptureFailureNotice")
struct CaptureFailureNoticeTests {
    @Test func failedCaptureNotifies() {
        #expect(CaptureFailureNotice.shouldNotify(captureHealthy: false, transcriptEmpty: true))
        #expect(CaptureFailureNotice.shouldNotify(captureHealthy: false, transcriptEmpty: false))
    }

    @Test func healthyShortOrScratchThatStaysSilent() {
        #expect(!CaptureFailureNotice.shouldNotify(captureHealthy: true, transcriptEmpty: true))
    }
}
