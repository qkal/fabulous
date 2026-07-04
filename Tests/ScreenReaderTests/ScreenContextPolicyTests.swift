import ScreenReader
import Testing

@Suite struct ScreenContextPolicyTests {
    @Test func disabledNeverCaptures() {
        #expect(!ScreenContextPolicy.shouldCapture(enabled: false, cleanupOn: true, engineBiases: true))
    }

    @Test func capturesWhenAnyConsumerExists() {
        #expect(ScreenContextPolicy.shouldCapture(enabled: true, cleanupOn: true, engineBiases: false))
        #expect(ScreenContextPolicy.shouldCapture(enabled: true, cleanupOn: false, engineBiases: true))
    }

    @Test func noConsumerNoCapture() {
        #expect(!ScreenContextPolicy.shouldCapture(enabled: true, cleanupOn: false, engineBiases: false))
    }
}
