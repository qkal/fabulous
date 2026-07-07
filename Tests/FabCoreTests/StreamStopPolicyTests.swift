import FabCore
import Testing

@Suite("StreamStopPolicy")
struct StreamStopPolicyTests {
    @Test func noSessionTrimsAtStopNoLazyTrim() {
        #expect(StreamStopPolicy.trimAtStop(hasSession: false))
        #expect(!StreamStopPolicy.needsLazyTrim(hasSession: false))
    }

    @Test func sessionStopsRawAndTrimsLazily() {
        #expect(!StreamStopPolicy.trimAtStop(hasSession: true))
        #expect(StreamStopPolicy.needsLazyTrim(hasSession: true))
    }
}
