import Foundation

/// A user-configured injection override for one app: which strategy the
/// chain starts at while that app is frontmost. Persisted by the app
/// layer; layered over `StrategySelector.defaultOverrides` (user wins).
public struct AppOverride: Codable, Sendable, Equatable {
    public var bundleID: String
    /// Persisted so the settings row still renders after the app is
    /// uninstalled — icons can fall back to a generic one, names can't.
    public var displayName: String
    public var strategy: InjectionStrategy

    public init(bundleID: String, displayName: String, strategy: InjectionStrategy) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.strategy = strategy
    }
}

extension StrategySelector {
    /// Built-in defaults with the user's overrides layered on top; the
    /// user wins on the same bundle ID (so an explicit axInsert entry is
    /// how a built-in terminal default gets neutralized). Later duplicates
    /// in `userOverrides` win over earlier ones.
    public init(userOverrides: [AppOverride]) {
        var merged = Self.defaultOverrides
        for entry in userOverrides {
            merged[entry.bundleID] = entry.strategy
        }
        self.init(overrides: merged)
    }
}
