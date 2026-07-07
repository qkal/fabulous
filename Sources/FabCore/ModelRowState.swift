import Foundation

/// Lifecycle status of one model row in the Models tab. Pure value type
/// (moved out of `ModelListModel` so its transitions are unit-testable).
public enum ModelRowStatus: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case installed
    case active
    case failed(String)
}

/// Events that drive a model row's status.
public enum ModelRowEvent: Equatable, Sendable {
    case downloadStarted
    case progress(Double)
    /// A download finished successfully; `isActive` when this model is the
    /// one currently loaded in the backend.
    case downloadSucceeded(isActive: Bool)
    case downloadFailed(String)
    /// Disk truth, recomputed by a Models-tab refresh.
    case reconcile(installed: Bool, isActive: Bool)
}

/// Pure reducer for a model row's status.
///
/// Fixes the download-stuck deadlock: previously the only transition to
/// `.installed`/`.active` was a refresh that *skipped* rows still `.downloading`
/// — so a finished download (left at `.downloading(1.0)`) was never promoted and
/// the row hung on a full bar until app restart. Here success is an explicit
/// event, and `reconcile` has defined precedence so it can neither clobber a
/// `.failed` message nor resurrect a finished download.
public enum ModelRowState {
    public static func reduce(_ status: ModelRowStatus, _ event: ModelRowEvent) -> ModelRowStatus {
        switch event {
        case .downloadStarted:
            return .downloading(0)
        case .progress(let fraction):
            // A stray/reordered progress tick can't resurrect a finished/failed row.
            guard case .downloading = status else { return status }
            return .downloading(fraction)
        case .downloadSucceeded(let isActive):
            return isActive ? .active : .installed
        case .downloadFailed(let message):
            return .failed(message)
        case .reconcile(let installed, let isActive):
            switch status {
            case .downloading:
                return status                       // genuinely in-flight; success owns the flip
            case .failed:
                return status                       // preserve the failure message
            default:
                if installed { return isActive ? .active : .installed }
                return .notInstalled
            }
        }
    }
}
