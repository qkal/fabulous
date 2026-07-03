import AppKit
import SwiftUI

/// Which of the two designed looks the app wears. Persisted by rawValue.
enum ThemeKind: String, CaseIterable, Sendable {
    case paper, glass

    var displayName: String {
        switch self {
        case .paper: "Paper"
        case .glass: "Glass"
        }
    }
}

/// System-appearance override. Persisted by rawValue.
enum AppearanceKind: String, CaseIterable, Sendable {
    case system, light, dark

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// nil = follow the system (clears any override).
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// A complete visual theme — every color/metric the views consume.
/// `.paper` adapts to the system appearance; `.glass` is fixed dark.
struct Theme: Sendable {
    enum PillStyle: Sendable {
        /// Frosted translucent material with a warm paper tint.
        case frosted
        /// The original near-black glass capsule with an ice glow.
        case glass
    }

    let paper: Color
    let card: Color
    let ink: Color
    let inkSecondary: Color
    let accent: Color
    let hairline: Color
    let paperNSColor: NSColor
    let cardRadius: CGFloat
    let pillStyle: PillStyle
    /// Voice-energy halo behind the pill. Only the `.glass` pill style
    /// consumes it; the frosted style uses a plain black drop shadow.
    let pillGlow: Color

    /// The paper-feel look: warm off-white / warm graphite, ink text,
    /// one blue accent. Colors adapt via dynamic NSColors.
    static let paper: Theme = {
        let paperNS = NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor(red: 0.145, green: 0.140, blue: 0.130, alpha: 1)  // #252421
                : NSColor(red: 0.969, green: 0.961, blue: 0.949, alpha: 1)  // #F7F5F2
        }
        let ink = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor(red: 0.925, green: 0.918, blue: 0.902, alpha: 1)
                : NSColor(red: 0.150, green: 0.140, blue: 0.120, alpha: 1)
        })
        return Theme(
            paper: Color(nsColor: paperNS),
            card: Color(nsColor: NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor(red: 0.190, green: 0.185, blue: 0.175, alpha: 1)
                    : NSColor(red: 0.995, green: 0.992, blue: 0.986, alpha: 1)
            }),
            ink: ink,
            inkSecondary: ink.opacity(0.55),
            accent: Color(red: 0.184, green: 0.435, blue: 0.929),  // #2F6FED
            hairline: ink.opacity(0.14),
            paperNSColor: paperNS,
            cardRadius: 12,
            pillStyle: .frosted,
            pillGlow: .black
        )
    }()

    /// The original black-glass look, extended to windows: dark graphite
    /// surfaces, ice text and accent. Fixed — Glass is always dark.
    static let glass: Theme = {
        let ice = Color(red: 0.88, green: 0.93, blue: 1.0)
        return Theme(
            paper: Color(red: 0.110, green: 0.106, blue: 0.102),   // #1C1B1A
            card: Color(red: 0.160, green: 0.155, blue: 0.150),
            ink: ice,
            inkSecondary: ice.opacity(0.55),
            accent: ice,
            hairline: ice.opacity(0.14),
            paperNSColor: NSColor(red: 0.110, green: 0.106, blue: 0.102, alpha: 1),
            cardRadius: 12,
            pillStyle: .glass,
            pillGlow: ice
        )
    }()

    static func current(_ kind: ThemeKind) -> Theme {
        switch kind {
        case .paper: .paper
        case .glass: .glass
        }
    }
}

extension EnvironmentValues {
    @Entry var theme: Theme = .paper
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
