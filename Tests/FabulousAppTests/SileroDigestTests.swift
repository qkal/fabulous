import Testing

@testable import FabulousApp

@Suite("Silero pinned digests")
struct SileroDigestTests {
    @Test func everyRequiredComponentHasAPinnedDigest() {
        for component in SileroVADInstaller.requiredComponents {
            #expect(SileroVADInstaller.expectedDigests[component] != nil, "missing digest for \(component)")
        }
    }
}
