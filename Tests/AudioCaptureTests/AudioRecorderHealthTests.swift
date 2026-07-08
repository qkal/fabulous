import AudioCapture
import Testing

@Suite("AudioRecorder health")
struct AudioRecorderHealthTests {
    @Test func freshRecorderIsHealthy() async {
        let r = AudioRecorder()
        #expect(await r.isHealthy)
    }
}
