import Foundation

/// How transcribed text gets into the frontmost app, ordered from most to
/// least preferred. See docs/architecture.md for the full rationale.
public enum InjectionStrategy: String, Sendable, Codable, Equatable, CaseIterable {
    /// Set kAXSelectedText on the focused element. Most reliable, no
    /// clipboard pollution — when the app implements the API honestly.
    case axInsert
    /// Save clipboard → set transcript → synthesize ⌘V → restore clipboard.
    case paste
    /// Synthesize unicode keystrokes. Slow, but works in apps that block
    /// paste (some terminals, remote desktops).
    case keystrokes
}

/// Everything the selector needs to know about the moment of injection.
/// Pure data, so selection logic is unit-testable without AppKit.
public struct InjectionContext: Sendable, Equatable {
    public var frontmostBundleID: String?
    /// A password field (or password manager) holds secure input; injecting
    /// would be swallowed or, worse, logged. We refuse instead.
    public var secureInputActive: Bool
    /// Without Accessibility we can neither read the focused element nor
    /// post synthetic events — no strategy can work.
    public var accessibilityTrusted: Bool

    public init(
        frontmostBundleID: String?,
        secureInputActive: Bool,
        accessibilityTrusted: Bool
    ) {
        self.frontmostBundleID = frontmostBundleID
        self.secureInputActive = secureInputActive
        self.accessibilityTrusted = accessibilityTrusted
    }
}

public enum InjectionDecision: Sendable, Equatable {
    case attempt(chain: [InjectionStrategy])
    case refuse(RefusalReason)
}

public enum RefusalReason: Sendable, Equatable {
    case secureInputActive
    case accessibilityNotGranted
}

/// Decides which strategies to try, in order, for a given context.
public struct StrategySelector: Sendable {
    /// Apps where the default chain misbehaves. Terminals commonly report
    /// AX success without inserting (or interpret inserted text oddly), so
    /// they start at paste.
    public static let defaultOverrides: [String: InjectionStrategy] = [
        "com.apple.Terminal": .paste,
        "com.googlecode.iterm2": .paste,
        "dev.warp.Warp-Stable": .paste,
        "com.github.wez.wezterm": .paste,
        "net.kovidgoyal.kitty": .paste,
        "org.alacritty": .paste,
    ]

    /// Display names for `defaultOverrides` entries, keyed identically —
    /// the settings UI can't ask NSWorkspace to name apps that aren't
    /// installed, and bundle IDs are ugly. Adding a built-in means adding
    /// to both maps (a test enforces the keys match).
    public static let builtInDisplayNames: [String: String] = [
        "com.apple.Terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm2",
        "dev.warp.Warp-Stable": "Warp",
        "com.github.wez.wezterm": "WezTerm",
        "net.kovidgoyal.kitty": "kitty",
        "org.alacritty": "Alacritty",
    ]

    public var overrides: [String: InjectionStrategy]

    public init(overrides: [String: InjectionStrategy] = StrategySelector.defaultOverrides) {
        self.overrides = overrides
    }

    public func select(for context: InjectionContext) -> InjectionDecision {
        if context.secureInputActive {
            return .refuse(.secureInputActive)
        }
        guard context.accessibilityTrusted else {
            return .refuse(.accessibilityNotGranted)
        }
        let start: InjectionStrategy =
            context.frontmostBundleID.flatMap { overrides[$0] } ?? .axInsert
        return .attempt(chain: Self.chain(startingAt: start))
    }

    /// The fallback chain from a starting strategy: each failure falls
    /// through to the next-less-clean approach.
    public static func chain(startingAt start: InjectionStrategy) -> [InjectionStrategy] {
        switch start {
        case .axInsert: [.axInsert, .paste, .keystrokes]
        case .paste: [.paste, .keystrokes]
        case .keystrokes: [.keystrokes]
        }
    }
}
