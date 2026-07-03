# Paper UI restyle — overlay pill + app surfaces

**Status:** implemented
**Date:** 2026-07-03

## Goal

Restyle fabulous to the "paper-feel" reference the user provided (warm
off-white surfaces, ink text, hairline borders, soft rounded cards, one blue
accent, quiet overall) — replacing the current black-glass/ice look. Two
surfaces: the floating dictation pill and the app windows (settings +
onboarding). Pure view-layer change; zero behavior changes.

## Design decisions (settled with the user)

- **Scope:** overlay pill AND app windows (settings tabs, onboarding).
- **Pill body:** frosted material (native macOS translucent material, warm
  tint) rather than literal paper — auto-adapts contrast over arbitrary app
  content and in dark mode.
- **Color:** moving parts in adaptive ink (dark-on-light / light-on-dark);
  a single blue accent reserved for the spinner head (and app-wide control
  tint). The user's chosen "blue volatile tail" is deferred — partials
  arrive as one joined string today; see Out of scope.

## Architecture

One new file owns every color/metric; existing views consume it.

### `Sources/FabulousApp/PaperTheme.swift` (new)

Static namespace, no state:

- `paper` — window/card background: warm off-white in light mode
  (≈ #F7F5F2), warm graphite in dark mode. Adaptive via
  `Color(nsColor: NSColor(name:dynamicProvider:))` or the
  `light:dark:` initializer pattern used with `NSAppearance` matching.
- `ink` / `inkSecondary` — primary and secondary text/wave color,
  adaptive (near-black on light, warm white on dark).
- `accent` — the single blue (≈ system blue tuned to the reference).
- `hairline` — border stroke color (ink at low opacity).
- `cardRadius` (12) and `pillShadow` constants.

### Overlay pill (`OverlayController.swift`)

- `CapsuleChrome`: black fill → frosted material. SwiftUI
  `.background(.ultraThinMaterial, in: Capsule(...))` with a warm
  `PaperTheme.paper.opacity(...)` tint layer, `PaperTheme.hairline`
  strokeBorder, soft y-offset shadow for lift. The voice-energy breathing
  stays (scale + shadow/border response) but expresses as ink-warm
  emphasis, not white glow.
- `SiriWave` bars: `PaperTheme.ink`, louder = more opaque (same envelope
  math, palette swap only).
- `CometSpinner`: track in `inkSecondary`, comet gradient ending in
  `accent` blue.
- Partial text: finalized portion `ink`, styling unchanged otherwise. The
  volatile tail is not separately addressable today (partials arrive as one
  joined string) — the whole partial line renders in `inkSecondary` with the
  last-word emphasis dropped; the blue-accent-on-volatile-tail idea is
  deferred until the session exposes the volatile span (noted in Out of
  scope).
- Message notices: same frosted capsule; the warning icon uses `accent`
  instead of yellow.

### App windows

Actual structure (verified): `SettingsView` is a `NavigationSplitView`
(sidebar `List` of sections → `.formStyle(.grouped)` forms), not tabs —
conveniently already the reference's sidebar-plus-cards shape.

- `SettingsView`: hide the default form/list chrome
  (`.scrollContentBackground(.hidden)` on forms and sidebar) and lay
  `PaperTheme.paper` behind both panes. Grouped-form section insets already
  render as rounded cards — they keep doing so over paper; no per-group
  wrapping needed. `SettingsWindowController` sets
  `window.backgroundColor` to the paper NSColor and
  `titlebarAppearsTransparent = true` so the title bar blends into the
  paper instead of striping.
- `OnboardingView`: paper background; the existing
  `.quaternary`-filled permission card becomes a `cardRadius` +
  `hairline` paper card.
- **Tint does not cross windows:** settings, onboarding, and the overlay
  panel are three separate `NSHostingView` roots — apply
  `.tint(PaperTheme.accent)` at each root (the existing
  `Color.accentColor.opacity(0.2)` status capsule in the Models tab then
  follows automatically).
- Menu bar menu and status item: untouched (system-drawn).

### Implementation risk (called out)

SwiftUI `.ultraThinMaterial` inside the clear, borderless overlay `NSPanel`
usually renders via a backing `NSVisualEffectView`, but clear-window blending
can surprise. If the material looks wrong (gray slab / no vibrancy), fall
back to an explicit `NSVisualEffectView` (`.hudWindow` or `.popover`
material, `state: .active`) behind the hosting view, masked to the capsule.
Verify over both light and dark content early in implementation.

## Error handling

None — pure presentation. The only runtime consideration: dynamic NSColor
providers must not capture non-Sendable state (Swift 6); use static
closures.

## Testing

No unit tests (SwiftUI view code in the executable target — repo
convention: verified by eye). Gates:

- `swift build --arch arm64` zero warnings.
- Full `swift test` still green (nothing outside FabulousApp views changes).
- Manual pass: pill over a white document and over a dark window (light +
  dark system appearance), recording wave, partial text, spinner, safety-net
  notice, settings all tabs, onboarding.

## Out of scope

- Blue accent on the volatile-tail span of partials (needs the session to
  emit finalized/volatile spans separately — protocol change, separate
  phase if wanted).
- Restructuring settings into the reference's sidebar-card web layout.
- App icon / status-item icon changes.
