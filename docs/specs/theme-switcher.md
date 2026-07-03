# Theme switcher — Paper/Glass + appearance override

**Status:** implemented
**Date:** 2026-07-03

## Goal

Settings-controlled theming for the entire app — settings window, onboarding,
and the dictation pill (wave, partials, spinner, notices). Two controls in a
new Settings → General → "Appearance" section:

- **Theme:** Paper (the current look) or Glass (the pre-restyle black-glass /
  ice look, revived).
- **Appearance:** System / Light / Dark — forces or follows the macOS
  appearance app-wide.

## Design decisions (settled with the user)

- Theme set: exactly Paper + Glass. No invented palettes.
- Glass extends to app windows: dark graphite backgrounds + ice text — the
  pill's aesthetic applied everywhere, not a pill-only skin.
- Appearance picker included. Glass forces dark mode app-wide while active
  (its fixed graphite surfaces need dark-mode native controls and label
  colors); the appearance preference is remembered and applies whenever
  Paper is active. The UI footnote says "Glass is always dark."

## Architecture

### `Sources/FabulousApp/Theme.swift` (replaces `PaperTheme.swift`)

- `enum ThemeKind: String, CaseIterable, Sendable` — `paper`, `glass`;
  `displayName`.
- `enum AppearanceKind: String, CaseIterable, Sendable` — `system`, `light`,
  `dark`; `displayName`; `var nsAppearance: NSAppearance?` (nil for system,
  `.aqua` / `.darkAqua` otherwise).
- `struct Theme: Sendable` — fields keep the current token names so view
  edits are mechanical: `paper`, `card`, `ink`, `inkSecondary`, `accent`,
  `hairline` (all `Color`), `paperNSColor: NSColor`, `cardRadius: CGFloat`,
  plus two new tokens: `pillStyle` (`enum PillStyle { case frosted, glass }`)
  and `pillGlow: Color` (voice-energy glow color — ice for glass, black for
  frosted; the old glass look's glow must come back or the revival reads
  flat).
- `static let paper = Theme(...)` — today's adaptive `PaperTheme` values
  verbatim (dynamic NSColor providers, static closures).
- `static let glass = Theme(...)` — fixed (non-adaptive) dark: graphite
  window (`≈ #1C1B1A`), lighter graphite cards, ice ink
  (`red: 0.88, green: 0.93, blue: 1.0` — the old `OverlayStyle.ice`), ice
  accent, `pillStyle: .glass`, `pillGlow` ice.
- `static func current(_ kind: ThemeKind) -> Theme`.
- SwiftUI environment key: `extension EnvironmentValues { @Entry var theme:
  Theme = .paper }`.

### Settings plumbing (`SettingsStore.swift`)

Follow the existing key/callback pattern (`transcriptionEngine` /
`onEngineChanged` is the template):

- `var theme: ThemeKind` (default `.paper`), `var appearance: AppearanceKind`
  (default `.system`) — both persisted to UserDefaults, read at init,
  `didSet` → `onThemeChanged` / `onAppearanceChanged` callbacks.
- New UserDefaults keys default to current behavior — existing installs see
  no change; no migration.

### Application (`AppController`)

- `start()`: apply appearance early (`NSApp.appearance =
  settings.appearance.nsAppearance`) — cascades to all windows including the
  overlay panel; push the current theme into `OverlayModel` before any show
  (the overlay's hosting view is created lazily at first show — without this
  the first pill after launch could render paper under a glass setting).
- `onAppearanceChanged`: re-apply `NSApp.appearance`. Nothing else — dynamic
  NSColors and materials resolve automatically.
- `onThemeChanged`: push theme into `OverlayModel`; tell
  `SettingsWindowController` and the onboarding window (if open) to re-apply
  `window.backgroundColor = theme.paperNSColor` — window background does NOT
  update itself on theme switch (unlike appearance switch, where the dynamic
  color resolves). Live switch: settings window repaints immediately.

### Views

- All `PaperTheme.x` references become `theme.x` via `@Environment(\.theme)`
  — including `SiriWave` and `CometSpinner`, which draw in `Canvas` and today
  reference the statics directly; each gets its own `@Environment(\.theme)`
  property (easy to miss — explicit requirement).
- Roots: settings root and onboarding root derive the theme from their
  observable store binding and set `.environment(\.theme, ...)` +
  `.tint(theme.accent)`; the overlay root reads `model.theme` (pushed by
  AppController) and does the same. Three roots, as with the paper restyle.
- `CapsuleChrome` branches on `theme.pillStyle`:
  - `.frosted` — today's material ZStack, black soft shadow.
  - `.glass` — the pre-restyle look: `.black.opacity(0.8)` capsule fill,
    white energy rim (`.white.opacity(0.14 + 0.3 * energy)`), ice glow
    shadow (`theme.pillGlow.opacity(0.3 * energy), radius: 12`) plus the
    black drop shadow. View-identity change on switch is harmless (a switch
    can't happen mid-recording from the settings window; worst case is one
    re-render).
- Settings → General gains an "Appearance" section above "Dictation hotkey":
  `Picker("Theme")` and `Picker("Appearance")`, both `.radioGroup`, plus the
  footnote text "Glass is always dark." under the appearance picker.

## Error handling

None — presentation plus two persisted enums. Unknown stored rawValue falls
back to the default (same guard pattern the engine setting uses).

## Testing

- `swift build --arch arm64` zero warnings; full `swift test` green (no
  library-target changes).
- All theme/appearance types live in the executable target — no unit tests
  (repo convention).
- Manual pass: switch Paper ↔ Glass with settings open (window + cards flip
  live), pill in both themes (frosted vs glass+glow) over light and dark
  content, appearance System/Light/Dark under Paper (paper-light ↔
  graphite), onboarding under Glass, notice + spinner + partials in both
  themes.

## Out of scope

- Additional palettes beyond Paper/Glass.
- Per-surface theme mixing (e.g. glass pill + paper windows).
- Menu bar / status item styling (system-drawn).
