import FabCore
import Testing

@Suite("ModelRowState")
struct ModelRowStateTests {
    @Test func downloadLifecycleReachesInstalled() {
        var s = ModelRowStatus.notInstalled
        s = ModelRowState.reduce(s, .downloadStarted)
        s = ModelRowState.reduce(s, .progress(0.5))
        s = ModelRowState.reduce(s, .progress(1.0))
        s = ModelRowState.reduce(s, .downloadSucceeded(isActive: false))
        #expect(s == .installed)
    }

    @Test func downloadSucceededActiveBecomesActive() {
        #expect(ModelRowState.reduce(.downloading(1.0), .downloadSucceeded(isActive: true)) == .active)
    }

    @Test func reconcileAfterSuccessKeepsInstalled() {
        // The exact deadlock: a finished download must not be re-skipped or reset.
        var s = ModelRowState.reduce(.downloading(1.0), .downloadSucceeded(isActive: false))
        s = ModelRowState.reduce(s, .reconcile(installed: true, isActive: false))
        #expect(s == .installed)
    }

    @Test func reconcileLeavesInFlightDownloadAlone() {
        #expect(ModelRowState.reduce(.downloading(0.4), .reconcile(installed: false, isActive: false)) == .downloading(0.4))
    }

    @Test func reconcileDoesNotClobberFailure() {
        #expect(ModelRowState.reduce(.failed("boom"), .reconcile(installed: false, isActive: false)) == .failed("boom"))
    }

    @Test func reconcilePromotesFreshInstallToActive() {
        #expect(ModelRowState.reduce(.notInstalled, .reconcile(installed: true, isActive: true)) == .active)
    }

    @Test func reconcileMarksMissingNotInstalled() {
        #expect(ModelRowState.reduce(.installed, .reconcile(installed: false, isActive: false)) == .notInstalled)
    }

    @Test func lateProgressAfterSuccessIsIgnored() {
        #expect(ModelRowState.reduce(.installed, .progress(0.9)) == .installed)
    }
}
