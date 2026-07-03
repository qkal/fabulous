import AppKit
import SwiftUI

/// The paper-feel palette — single source of truth for the restyle.
/// Warm off-white surfaces, ink text, hairline borders, one blue accent.
/// Every color adapts to the system appearance via a dynamic NSColor.
enum PaperTheme {
    /// Window background: warm paper in light mode, warm graphite in dark.
    static let paperNSColor = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(red: 0.145, green: 0.140, blue: 0.130, alpha: 1)  // #252421
            : NSColor(red: 0.969, green: 0.961, blue: 0.949, alpha: 1)  // #F7F5F2
    }
    static let paper = Color(nsColor: paperNSColor)

    /// Card fill: lifted slightly off the paper (near-white / lighter graphite).
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(red: 0.190, green: 0.185, blue: 0.175, alpha: 1)
            : NSColor(red: 0.995, green: 0.992, blue: 0.986, alpha: 1)
    })

    /// Primary text / wave color: near-black ink, warm white in dark mode.
    static let ink = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(red: 0.925, green: 0.918, blue: 0.902, alpha: 1)
            : NSColor(red: 0.150, green: 0.140, blue: 0.120, alpha: 1)
    })

    static let inkSecondary = ink.opacity(0.55)

    /// The one blue accent (spinner head, control tint).
    static let accent = Color(red: 0.184, green: 0.435, blue: 0.929)  // #2F6FED

    /// Hairline border stroke.
    static let hairline = ink.opacity(0.14)

    static let cardRadius: CGFloat = 12
}

extension NSAppearance {
    fileprivate var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
