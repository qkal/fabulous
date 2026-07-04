import FabCore
import Foundation

/// Seam for AppController orchestration and tests: the live reader walks
/// AX; fakes return canned contexts.
public protocol ScreenContextReading: Sendable {
    /// Reads the focused window of `pid`. Never throws — any failure
    /// (no AX tree, timeout, dead pid) returns an empty context and the
    /// dictation proceeds exactly as without the feature.
    func read(pid: pid_t) async -> ScreenContext
}
