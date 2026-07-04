import Foundation

/// What the screen reader saw at recording start: the focused window's
/// title and the dictation-relevant vocabulary extracted from its visible
/// text. Ephemeral — lives for one dictation, never persisted or logged
/// verbatim (privacy invariant; log term counts only). No `appName`: it
/// flows separately via `setAppContext`, and resolving it needs AppKit.
public struct ScreenContext: Sendable, Equatable {
    public let windowTitle: String?
    public let terms: [String]
    public let capturedAt: Date

    public init(windowTitle: String?, terms: [String], capturedAt: Date) {
        self.windowTitle = windowTitle
        self.terms = terms
        self.capturedAt = capturedAt
    }
}
