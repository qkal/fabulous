# Theme Switcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Settings-controlled theming — Paper or Glass for the whole app (windows + dictation pill), plus a System/Light/Dark appearance override.

**Architecture:** `PaperTheme` static namespace becomes a `Theme` value struct (two instances: `.paper` with today's adaptive tokens, `.glass` reviving the pre-restyle black-glass/ice look, extended to windows as dark graphite + ice). Distribution via a SwiftUI `@Entry` environment key set at the three hosting roots; persistence and change callbacks follow `SettingsStore`'s existing pattern; `NSApp.appearance` handles the appearance override app-wide.

**Tech Stack:** SwiftUI on macOS, Swift 6 strict concurrency, SwiftPM.

**Spec:** `docs/specs/theme-switcher.md` — read it first.

## Global Constraints

- `swift build --arch arm64` only; zero warnings under Swift 6 strict concurrency — warnings are failures.
- All changes in `Sources/FabulousApp` (executable target) — no unit tests possible; gates are a clean build and the full `swift test` suite staying green (82 tests).
- No behavior changes outside theming.
- Exact token field names carry over from `PaperTheme` so view edits are mechanical: `paper`, `card`, `ink`, `inkSecondary`, `accent`, `hairline`, `paperNSColor`, `cardRadius`.
- New UserDefaults keys default to `paper` / `system` — existing installs see no change.
- Tint/environment do not cross windows: all three hosting roots (overlay, settings, onboarding) set `.environment(\.theme, …)` and `.tint(theme.accent)`.
- Run all commands from repo root `/Users/kal/fabulous`; commit after every task.

---

### Task 1: `Theme` types (coexisting with `PaperTheme`)

**Files:**
- Create: `Sources/FabulousApp/Theme.swift`

`PaperTheme.swift` stays until Task 5 — both compile side by side so every task builds green.

**Interfaces:**
- Produces (exact names later tasks rely on):
  - `enum ThemeKind: String, CaseIterable, Sendable` — `.paper`, `.glass`, `var displayName: String`
  - `enum AppearanceKind: String, CaseIterable, Sendable` — `.system`, `.light`, `.dark`, `var displayName: String`, `var nsAppearance: NSAppearance?`
  - `struct Theme: Sendable` — fields `paper/card/ink/inkSecondary/accent/hairline: Color`, `paperNSColor: NSColor`, `cardRadius: CGFloat`, `pillStyle: PillStyle`, `pillGlow: Color`; `enum PillStyle: Sendable { case frosted, glass }`
  - `Theme.paper`, `Theme.glass`, `static func current(_ kind: ThemeKind) -> Theme`
  - `EnvironmentValues.theme` (`@Entry`, default `.paper`)

- [ ] **Step 1: Write the file**

```swift
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
    /// Voice-energy halo behind the pill (ice for glass, plain black
    /// drop shadow for frosted).
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
```

Note: `NSAppearance.isDark` here is internal (not fileprivate) and duplicates the `fileprivate` one in `PaperTheme.swift` — that's fine while both files exist (different access scopes, no redeclaration conflict is expected since the PaperTheme one is fileprivate; if the compiler still reports a conflict, rename PaperTheme's to `isDarkLegacy` inside that file — it dies in Task 5 anyway).

- [ ] **Step 2: Build + test**

Run: `cd /Users/kal/fabulous && swift build --arch arm64 && swift test`
Expected: zero warnings, 82 tests green.

- [ ] **Step 3: Commit**

```bash
git add Sources/FabulousApp/Theme.swift
git commit -m "Theme: Paper/Glass value type, appearance kinds, environment key"
```

---

### Task 2: SettingsStore persistence + callbacks

**Files:**
- Modify: `Sources/FabulousApp/SettingsStore.swift`

**Interfaces:**
- Consumes: `ThemeKind`, `AppearanceKind` (Task 1).
- Produces: `SettingsStore.theme: ThemeKind` (default `.paper`), `SettingsStore.appearance: AppearanceKind` (default `.system`), `onThemeChanged: (() -> Void)?`, `onAppearanceChanged: (() -> Void)?`. Pattern is `transcriptionEngine`/`onEngineChanged`, copied exactly.

- [ ] **Step 1: Add keys, callbacks, properties, init reads**

In `Keys`, after `replacementEntries`:

```swift
        static let theme = "theme"
        static let appearance = "appearance"
```

After the `onEngineChanged` declaration:

```swift
    @ObservationIgnored var onThemeChanged: (() -> Void)?
    @ObservationIgnored var onAppearanceChanged: (() -> Void)?
```

After the `soundCuesEnabled` property:

```swift
    /// Visual theme for the whole app, including the dictation pill.
    var theme: ThemeKind {
        didSet {
            guard theme != oldValue else { return }
            defaults.set(theme.rawValue, forKey: Keys.theme)
            onThemeChanged?()
        }
    }

    /// System-appearance override (System / Light / Dark).
    var appearance: AppearanceKind {
        didSet {
            guard appearance != oldValue else { return }
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            onAppearanceChanged?()
        }
    }
```

In `init`, after the `soundCuesEnabled` line:

```swift
        theme = defaults.string(forKey: Keys.theme)
            .flatMap(ThemeKind.init(rawValue:))
            ?? .paper
        appearance = defaults.string(forKey: Keys.appearance)
            .flatMap(AppearanceKind.init(rawValue:))
            ?? .system
```

- [ ] **Step 2: Build + test, commit**

Run: `cd /Users/kal/fabulous && swift build --arch arm64 && swift test`
Expected: zero warnings, green.

```bash
git add Sources/FabulousApp/SettingsStore.swift
git commit -m "SettingsStore: theme + appearance preferences with change callbacks"
```

---

### Task 3: Overlay pill — theme-driven, glass branch

**Files:**
- Modify: `Sources/FabulousApp/OverlayController.swift`

**Interfaces:**
- Consumes: `Theme`, `EnvironmentValues.theme` (Task 1).
- Produces: `OverlayController.applyTheme(_ theme: Theme)` — Task 5's AppController calls this at start and on change.

- [ ] **Step 1: Model + controller**

In `OverlayModel`, after `partialText`:

```swift
    /// Active theme, pushed by AppController (the overlay has no store
    /// binding). Set before the first show and on every theme change.
    var theme: Theme = .paper
```

In `OverlayController`, after `updatePartial`:

```swift
    /// Applies a theme; safe to call while the pill is visible.
    func applyTheme(_ theme: Theme) {
        model.theme = theme
    }
```

- [ ] **Step 2: OverlayView reads the model's theme**

In `OverlayView.body`, replace the three direct `PaperTheme` references and the tint, and inject the environment for child views. The full modifier chain at the bottom becomes:

```swift
        .scaleEffect(model.visible ? 1 : 0.6, anchor: .bottom)
        .offset(y: model.visible ? 0 : 16)
        .opacity(model.visible ? 1 : 0)
        .blur(radius: model.visible ? 0 : 3)
        .animation(.spring(response: 0.34, dampingFraction: 0.7), value: model.visible)
        .frame(width: 360, height: 72)
        .animation(.easeOut(duration: 0.18), value: model.phase)
        .environment(\.theme, model.theme)
        .tint(model.theme.accent)
```

And in the phase cases: partial text `foregroundStyle(PaperTheme.inkSecondary)` → `foregroundStyle(model.theme.inkSecondary)`; notice icon `PaperTheme.accent` → `model.theme.accent`; notice text `PaperTheme.ink.opacity(0.9)` → `model.theme.ink.opacity(0.9)`.

- [ ] **Step 3: CapsuleChrome branches on pill style**

Replace `CapsuleChrome` entirely:

```swift
/// The capsule shell — frosted paper or the original black glass, chosen by
/// the theme. `energy` (the live voice level) swells the capsule a few
/// percent and wakes the rim/halo so the object feels alive while you speak.
private struct CapsuleChrome<Content: View>: View {
    var energy: CGFloat = 0
    @ViewBuilder let content: Content

    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch theme.pillStyle {
            case .frosted:
                padded
                    .background {
                        ZStack {
                            Capsule(style: .continuous)
                                .fill(.ultraThinMaterial)
                            // Warm paper tint over the material so the frost
                            // reads paper, not gray.
                            Capsule(style: .continuous)
                                .fill(theme.paper.opacity(0.42))
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    theme.ink.opacity(0.14 + 0.25 * energy),
                                    lineWidth: 1
                                )
                        }
                    }
                    .scaleEffect(1 + energy * 0.045)
                    .shadow(color: .black.opacity(0.10 + 0.10 * energy), radius: 14, y: 4)
            case .glass:
                padded
                    .background(
                        Capsule(style: .continuous)
                            .fill(.black.opacity(0.8))
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(
                                        .white.opacity(0.14 + 0.3 * energy),
                                        lineWidth: 1
                                    )
                            )
                    )
                    .scaleEffect(1 + energy * 0.045)
                    .shadow(color: theme.pillGlow.opacity(0.3 * energy), radius: 12, y: 0)
                    .shadow(color: .black.opacity(0.4), radius: 9, y: 3)
            }
        }
        .animation(.easeOut(duration: 0.12), value: energy)
    }

    private var padded: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
    }
}
```

- [ ] **Step 4: SiriWave + CometSpinner read the environment**

In `SiriWave`, add below `var energetic: Bool`:

```swift
    @Environment(\.theme) private var theme
```

and the Canvas fill line becomes:

```swift
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(theme.ink.opacity(0.40 + 0.60 * min(1, heat)))
                    )
```

In `CometSpinner`, add at the top of the struct:

```swift
    @Environment(\.theme) private var theme
```

and replace the two `PaperTheme` strokes: track `theme.ink.opacity(0.18)`; comet gradient colors `theme.accent.opacity(0)` → `theme.accent`.

- [ ] **Step 5: Build + test, commit**

Run: `cd /Users/kal/fabulous && swift build --arch arm64 && swift test`
Expected: zero warnings, green (file must contain zero remaining `PaperTheme` references — grep before committing: `grep -c PaperTheme Sources/FabulousApp/OverlayController.swift` → 0).

```bash
git add Sources/FabulousApp/OverlayController.swift
git commit -m "Overlay: theme-driven pill with frosted/glass chrome branch"
```

---

### Task 4: Settings — picker UI + theme-driven backgrounds

**Files:**
- Modify: `Sources/FabulousApp/SettingsView.swift`
- Modify: `Sources/FabulousApp/SettingsWindowController.swift`

**Interfaces:**
- Consumes: `Theme`, `ThemeKind`, `AppearanceKind`, `SettingsStore.theme/.appearance` (Tasks 1–2).
- Produces: `SettingsWindowController.refreshBackground(_ color: NSColor)` — Task 5's AppController calls it on theme change.

- [ ] **Step 1: Root derives the theme**

In `SettingsRootView`, add a computed property above `body`:

```swift
    private var theme: Theme { Theme.current(store.theme) }
```

and replace the root's closing modifiers (`.background(PaperTheme.paper)`, `.tint(PaperTheme.accent)`) plus add the environment:

```swift
        .background(theme.paper)
        .environment(\.theme, theme)
        .tint(theme.accent)
        .frame(minWidth: 640, minHeight: 420)
```

The sidebar `List`'s `.background(PaperTheme.paper)` becomes `.background(theme.paper)` (it's inside `SettingsRootView`, which has the computed property).

- [ ] **Step 2: Panes read the environment**

Each of the four panes (`GeneralSettingsPane`, `ModelsSettingsPane`, `ReplacementsSettingsPane`, `HistorySettingsPane`) gets:

```swift
    @Environment(\.theme) private var theme
```

and its `.background(PaperTheme.paper)` becomes `.background(theme.paper)`. The hotkey-capture stroke in `GeneralSettingsPane` (`capturing ? Color.accentColor : ...`) is already tint-driven — leave it.

- [ ] **Step 3: Appearance section**

In `GeneralSettingsPane`'s `Form`, add as the FIRST section (above `Section("Dictation hotkey")`):

```swift
            Section("Appearance") {
                Picker("Theme", selection: $store.theme) {
                    ForEach(ThemeKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.radioGroup)
                Picker("Appearance", selection: $store.appearance) {
                    ForEach(AppearanceKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Glass is always dark.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 4: Window controller**

In `SettingsWindowController`, the creation-time line `window.backgroundColor = PaperTheme.paperNSColor` becomes:

```swift
            window.backgroundColor = Theme.current(store.theme).paperNSColor
```

(the `store` parameter is already in scope in `show`). Add a method after `show`:

```swift
    /// Repaints the window chrome on a live theme switch — the dynamic
    /// NSColor handles appearance changes by itself, but not theme changes.
    func refreshBackground(_ color: NSColor) {
        window?.backgroundColor = color
    }
```

- [ ] **Step 5: Build + test, commit**

Run: `cd /Users/kal/fabulous && swift build --arch arm64 && swift test && grep -c PaperTheme Sources/FabulousApp/SettingsView.swift Sources/FabulousApp/SettingsWindowController.swift`
Expected: zero warnings, green, grep prints 0 for both files.

```bash
git add Sources/FabulousApp/SettingsView.swift Sources/FabulousApp/SettingsWindowController.swift
git commit -m "Settings: theme/appearance pickers, theme-driven chrome"
```

---

### Task 5: Onboarding + AppController wiring; delete `PaperTheme`

**Files:**
- Modify: `Sources/FabulousApp/OnboardingView.swift`
- Modify: `Sources/FabulousApp/AppController.swift`
- Delete: `Sources/FabulousApp/PaperTheme.swift`

**Interfaces:**
- Consumes: everything above — `Theme.current`, `SettingsStore.theme/.appearance` + callbacks, `OverlayController.applyTheme`, `SettingsWindowController.refreshBackground`.
- Produces: the user-visible feature; no new API.

- [ ] **Step 1: OnboardingView observes the store**

`OnboardingView` currently has no store. Give it one so a live theme switch repaints an open onboarding window:

```swift
struct OnboardingView: View {
    @Bindable var store: SettingsStore
    // …existing @State properties unchanged…
```

Add a computed property above `body`:

```swift
    private var theme: Theme { Theme.current(store.theme) }
```

Replace `PaperTheme` references: `.background(PaperTheme.paper)` → `.background(theme.paper)`, `.tint(PaperTheme.accent)` → `.tint(theme.accent)`, and in `permissionRow`'s background `PaperTheme.cardRadius`/`PaperTheme.card`/`PaperTheme.hairline` → `theme.cardRadius`/`theme.card`/`theme.hairline`. `permissionRow` is a method of the same struct — it sees the computed `theme`; no environment plumbing needed.

- [ ] **Step 2: AppController creates it with the store, wires callbacks**

In `showOnboarding()`, the view creation becomes:

```swift
        let view = OnboardingView(store: settings, hotkeyName: settings.hotkeySpec.displayName) { [weak self] in
```

(keep the existing closure body), and `window.backgroundColor = PaperTheme.paperNSColor` becomes:

```swift
        window.backgroundColor = Theme.current(settings.theme).paperNSColor
```

In `start()`, immediately after `connectivity.start()`:

```swift
        NSApp.appearance = settings.appearance.nsAppearance
        overlay.applyTheme(Theme.current(settings.theme))
```

Next to the existing `settings.onEngineChanged = …` wiring, add:

```swift
        settings.onThemeChanged = { [weak self] in
            guard let self else { return }
            let theme = Theme.current(settings.theme)
            overlay.applyTheme(theme)
            settingsWindow.refreshBackground(theme.paperNSColor)
            onboardingWindow?.backgroundColor = theme.paperNSColor
        }
        settings.onAppearanceChanged = { [weak self] in
            guard let self else { return }
            NSApp.appearance = settings.appearance.nsAppearance
        }
```

- [ ] **Step 3: Delete the old namespace**

```bash
rm Sources/FabulousApp/PaperTheme.swift
grep -rn "PaperTheme" Sources/ || echo CLEAN
```

Expected: `CLEAN`. (If Task 1 renamed PaperTheme's `isDark` helper, nothing to restore — Theme.swift carries its own.)

- [ ] **Step 4: Build + test, commit**

Run: `cd /Users/kal/fabulous && swift build --arch arm64 && swift test`
Expected: zero warnings, 82 green.

```bash
git add -A
git commit -m "Theme switcher wired end-to-end; retire PaperTheme namespace"
```

---

### Task 6: Bundle + docs

**Files:**
- Modify: `docs/specs/theme-switcher.md` (status)
- Modify: `CLAUDE.md` (Done list)

- [ ] **Step 1: Bundle**

```bash
cd /Users/kal/fabulous && swift test && scripts/build.sh
```

(Keychain lock → `security unlock-keychain -p fabulous-dev-local ~/Library/Keychains/fabulous-dev.keychain-db`.) Do not open the app — the human runs the visual pass.

- [ ] **Step 2: Docs**

- `docs/specs/theme-switcher.md`: `**Status:** approved design, not yet implemented` → `**Status:** implemented`.
- `CLAUDE.md` Done list: the paper-restyle clause ends `paper settings/onboarding` — extend it to `paper settings/onboarding, theme switcher (Paper/Glass + System/Light/Dark appearance, docs/specs/theme-switcher.md)`.

- [ ] **Step 3: Commit**

```bash
git add docs/specs/theme-switcher.md CLAUDE.md
git commit -m "docs: theme switcher shipped"
```
