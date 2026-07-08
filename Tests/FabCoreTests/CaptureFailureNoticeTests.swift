import FabCore
import Testing

@Suite("CaptureFailureNotice")
struct CaptureFailureNoticeTests {
    @Test func failedCaptureNotifies() {
        #expect(CaptureFailureNotice.shouldNotify(captureHealthy: false))
    }

    @Test func healthyShortOrScratchThatStaysSilent() {
        #expect(!CaptureFailureNotice.shouldNotify(captureHealthy: true))
    }
}
