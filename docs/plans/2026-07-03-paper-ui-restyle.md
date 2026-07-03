# Paper UI Restyle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the dictation pill and app windows to the user's paper-feel reference: warm paper surfaces, ink text, hairline borders, one blue accent; pill becomes frosted material.

**Architecture:** One new `PaperTheme` namespace owns every color/metric; `OverlayController`, `SettingsView`/`SettingsWindowController`, and `OnboardingView` (+ its window in `AppController`) consume it. Pure view layer — zero behavior changes, no test-target changes.

**Tech Stack:** SwiftUI on macOS, Swift 6 strict concurrency, SwiftPM.

**Spec:** `docs/specs/paper-ui-restyle.md` — read it first.

## Global Constraints

- `swift build --arch arm64` only; zero warnings under Swift 6 strict concurrency — warnings are failures.
- No behavior changes: the only edits are colors, backgrounds, borders, tint. Do not touch state machines, actions, or layout logic beyond what a background/tint requires.
- All restyled surfaces are in `Sources/FabulousApp` (executable target) — no unit tests possible (`@testable import` unavailable); the gate per task is a clean build, and the full `swift test` suite must stay green (it never touches these files).
- Dynamic `NSColor` providers must not capture non-Sendable state — static closures only.
- Tint does not cross windows: `.tint(PaperTheme.accent)` must be applied at each of the three hosting roots (overlay view, settings root, onboarding root).
- Run all commands from repo root `/Users/kal/fabulous`; never cd into `.build/checkouts`.
- Commit after every task.

---

### Task 1: `PaperTheme` token file

**Files:**
- Create: `Sources/FabulousApp/PaperTheme.swift`

**Interfaces:**
- Produces (later tasks rely on these exact names):
  - `PaperTheme.paper: Color` — window background (warm off-white / warm graphite)
  - `PaperTheme.paperNSColor: NSColor` — same, for `NSWindow.backgroundColor`
  - `PaperTheme.card: Color` — card fill, slightly lifted off paper
  - `PaperTheme.ink: Color`, `PaperTheme.inkSecondary: Color`
  - `PaperTheme.accent: Color` — the single blue
  - `PaperTheme.hairline: Color` — border stroke
  - `PaperTheme.cardRadius: CGFloat` (12)

- [ ] **Step 1: Write the file**

```swift
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
```

- [ ] **Step 2: Build**

Run: `cd /Users/kal/fabulous && swift build --arch arm64`
Expected: compiles, zero warnings. (If `NSColor(name:dynamicProvider:)` trips a Sendable diagnostic, the closures are already static/capture-free — check for accidental captures rather than adding `@unchecked`.)

- [ ] **Step 3: Commit**

```bash
git add Sources/FabulousApp/PaperTheme.swift
git commit -m "PaperTheme: adaptive paper palette tokens"
```

---

### Task 2: Frosted paper pill (OverlayController)

**Files:**
- Modify: `Sources/FabulousApp/OverlayController.swift`

**Interfaces:**
- Consumes: `PaperTheme.*` from Task 1.
- Produces: no API changes — `OverlayController`'s public surface is untouched.

Current file: black-glass `CapsuleChrome`, monochrome `OverlayStyle.ice` palette used by the wave, spinner, and partial text. All changes below are palette/background swaps; keep every animation, envelope, and layout constant unchanged unless named here.

- [ ] **Step 1: Delete `OverlayStyle`, restyle `CapsuleChrome`**

Remove the `OverlayStyle` enum entirely (its only member is `ice`). Replace `CapsuleChrome`'s `body` with:

```swift
    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background {
                ZStack {
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                    // Warm paper tint over the material so the frost reads
                    // paper, not gray.
                    Capsule(style: .continuous)
                        .fill(PaperTheme.paper.opacity(0.42))
                    Capsule(style: .continuous)
                        .strokeBorder(
                            PaperTheme.ink.opacity(0.14 + 0.25 * energy),
                            lineWidth: 1
                        )
                }
            }
            .scaleEffect(1 + energy * 0.045)
            .shadow(color: .black.opacity(0.10 + 0.10 * energy), radius: 14, y: 4)
            .animation(.easeOut(duration: 0.12), value: energy)
    }
```

(The voice-energy breathing survives: scale + border/shadow warmth. The old white-glow shadow is gone by design.)

- [ ] **Step 2: Wave, spinner, partial text, notice**

In `SiriWave`'s Canvas fill, replace the ice color line:

```swift
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(PaperTheme.ink.opacity(0.40 + 0.60 * min(1, heat)))
                    )
```

In `CometSpinner`, replace both strokes:

```swift
                // The faint full track grounds the motion.
                Circle()
                    .stroke(PaperTheme.ink.opacity(0.18), lineWidth: 2.5)
                // The comet: a gradient tail ending in the blue accent head.
                Circle()
                    .trim(from: 0.08, to: 0.42)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                PaperTheme.accent.opacity(0),
                                PaperTheme.accent,
                            ]),
                            center: .center,
                            startAngle: .degrees(0.08 * 360),
                            endAngle: .degrees(0.42 * 360)
                        ),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(angle)
```

Partial-text line (in the `.recording` case): `foregroundStyle` becomes `PaperTheme.inkSecondary` (was `OverlayStyle.ice.opacity(0.75)`).

Message notice: the `exclamationmark.circle.fill` icon `foregroundStyle` becomes `PaperTheme.accent` (was `.yellow`); the notice `Text` becomes `PaperTheme.ink.opacity(0.9)` (was `.white.opacity(0.9)`).

- [ ] **Step 3: Tint root**

In `OverlayView.body`, append `.tint(PaperTheme.accent)` after the existing `.animation(.easeOut(duration: 0.18), value: model.phase)` modifier.

- [ ] **Step 4: Build + material smoke check**

Run: `cd /Users/kal/fabulous && swift build --arch arm64 && swift test`
Expected: zero warnings, all tests green.

Then the spec's called-out risk — material in a clear borderless panel: `CONFIG=debug scripts/build.sh && open build/fabulous.app`, start a recording over a white window and over a dark window. The capsule must read as warm frosted paper with a visible hairline, not an opaque gray slab, in both. If it fails, implement the spec's fallback (explicit `NSVisualEffectView`, `material: .hudWindow`, `state: .active`, masked to the capsule, behind the hosting view) and note it in your report. Quit the app after checking.

- [ ] **Step 5: Commit**

```bash
git add Sources/FabulousApp/OverlayController.swift
git commit -m "Overlay: frosted paper pill, ink wave, blue comet head"
```

---

### Task 3: Paper settings window

**Files:**
- Modify: `Sources/FabulousApp/SettingsView.swift`
- Modify: `Sources/FabulousApp/SettingsWindowController.swift`

**Interfaces:**
- Consumes: `PaperTheme.paper`, `PaperTheme.paperNSColor`, `PaperTheme.accent`.
- Produces: no API changes.

`SettingsRootView` is a `NavigationSplitView` (sidebar `List` → grouped `Form` panes). Grouped-form sections already draw rounded near-white cards — over paper they become the reference's cards for free. Only backgrounds and tint change.

- [ ] **Step 1: SettingsRootView backgrounds + tint**

In `SettingsRootView.body`, restyle both columns:

```swift
    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .scrollContentBackground(.hidden)
            .background(PaperTheme.paper)
        } detail: {
            detailView
                .navigationTitle(section.title)
        }
        .background(PaperTheme.paper)
        .tint(PaperTheme.accent)
        .frame(minWidth: 640, minHeight: 420)
    }
```

Then in each of the four panes (`GeneralSettingsPane`, `ModelsSettingsPane`, `ReplacementsSettingsPane`, `HistorySettingsPane`), add two modifiers directly after the existing `.formStyle(.grouped)`:

```swift
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(PaperTheme.paper)
```

(Four places; `GeneralSettingsPane` keeps its `.onAppear`/`.onDisappear` after these.)

- [ ] **Step 2: Window chrome**

In `SettingsWindowController`, after `window.styleMask = [...]` add:

```swift
            window.titlebarAppearsTransparent = true
            window.backgroundColor = PaperTheme.paperNSColor
```

- [ ] **Step 3: Build + eye check**

Run: `cd /Users/kal/fabulous && swift build --arch arm64 && swift test`
Expected: zero warnings, all green. `CONFIG=debug scripts/build.sh && open build/fabulous.app`, open Settings from the menu: paper background in sidebar + all four panes, section cards floating on paper, titlebar blended (no white strip), controls (radio pickers, toggles, download buttons, progress bar, "Recommended" capsule) tinted blue. Check dark mode via System Settings → Appearance if quick. Quit after.

- [ ] **Step 4: Commit**

```bash
git add Sources/FabulousApp/SettingsView.swift Sources/FabulousApp/SettingsWindowController.swift
git commit -m "Settings: paper background, blended titlebar, blue tint"
```

---

### Task 4: Paper onboarding

**Files:**
- Modify: `Sources/FabulousApp/OnboardingView.swift`
- Modify: `Sources/FabulousApp/AppController.swift` (showOnboarding window setup only)

**Interfaces:**
- Consumes: `PaperTheme.paper`, `PaperTheme.paperNSColor`, `PaperTheme.card`, `PaperTheme.hairline`, `PaperTheme.cardRadius`, `PaperTheme.accent`.
- Produces: no API changes.

- [ ] **Step 1: View background + tint**

In `OnboardingView.body`, on the outer `VStack`, replace:

```swift
        .padding(24)
        .frame(width: 460)
```

with:

```swift
        .padding(24)
        .frame(width: 460)
        .background(PaperTheme.paper)
        .tint(PaperTheme.accent)
```

- [ ] **Step 2: Permission cards**

In `permissionRow`, replace the `.background(...)` line:

```swift
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: PaperTheme.cardRadius)
                .fill(PaperTheme.card)
                .strokeBorder(PaperTheme.hairline, lineWidth: 1)
        )
```

Note: `.fill(...).strokeBorder(...)` doesn't chain on a Shape in one expression — if the compiler objects, use:

```swift
        .background(
            RoundedRectangle(cornerRadius: PaperTheme.cardRadius)
                .fill(PaperTheme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: PaperTheme.cardRadius)
                        .strokeBorder(PaperTheme.hairline, lineWidth: 1)
                )
        )
```

The green check / secondary dashed circle stay as they are (the reference uses green checks too).

- [ ] **Step 3: Onboarding window chrome**

In `AppController.showOnboarding()`, after `window.styleMask = [.titled, .closable]` add:

```swift
        window.titlebarAppearsTransparent = true
        window.backgroundColor = PaperTheme.paperNSColor
```

- [ ] **Step 4: Build + eye check + commit**

Run: `cd /Users/kal/fabulous && swift build --arch arm64 && swift test`
Expected: zero warnings, all green. Eye check: menu bar → Setup… → paper window, two hairline cards, blue "Grant Access"/default-action buttons.

```bash
git add Sources/FabulousApp/OnboardingView.swift Sources/FabulousApp/AppController.swift
git commit -m "Onboarding: paper window with hairline permission cards"
```

---

### Task 5: Final verification + docs

**Files:**
- Modify: `docs/specs/paper-ui-restyle.md` (status line)
- Modify: `CLAUDE.md` (one Done-list clause)

- [ ] **Step 1: Full build + bundle**

```bash
cd /Users/kal/fabulous && swift test && scripts/build.sh && open build/fabulous.app
```

(Keychain lock → `security unlock-keychain -p fabulous-dev-local ~/Library/Keychains/fabulous-dev.keychain-db`.)

Manual pass (the human does the by-voice parts): pill over light and dark content in both appearances — wave ink, partial text ink-secondary, spinner blue-headed, safety-net notice frosted with blue icon; settings all four panes; onboarding.

- [ ] **Step 2: Docs**

`docs/specs/paper-ui-restyle.md`: `**Status:** approved design, not yet implemented` → `**Status:** implemented`.

`CLAUDE.md` Done list (State / roadmap): append `; paper UI restyle (docs/specs/paper-ui-restyle.md): PaperTheme tokens, frosted paper pill, paper settings/onboarding` to the phase-5 sentence's end (before the final period).

- [ ] **Step 3: Commit**

```bash
git add docs/specs/paper-ui-restyle.md CLAUDE.md
git commit -m "docs: paper UI restyle shipped"
```
