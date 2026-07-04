# Per-App Injection Overrides Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** User-editable per-app injection overrides — pick which injection strategy fabulous tries first in a given app — persisted in settings, edited in a new "Apps" settings tab.

**Architecture:** New `AppOverride` value type + a `StrategySelector(userOverrides:)` merge initializer in the `TextInjector` target (pure, unit-tested). `SettingsStore` persists `[AppOverride]` as JSON in UserDefaults with an `onAppOverridesChanged` callback (exact replacements pattern). `AppController` rebuilds the selector and assigns it to the long-lived `TextInjector` (whose `selector` becomes `public var`) — the injector instance is never recreated, so the pending clipboard `restoreTask` invariant is untouched. New `AppsSettingsPane` in the settings window shows built-in terminal defaults (greyed, badged) and user rows in one sorted list.

**Tech Stack:** Swift 6 strict concurrency, SwiftPM, Swift Testing (NOT XCTest), SwiftUI settings panes, AppKit (NSOpenPanel/NSWorkspace) in app layer only.

**Spec:** `docs/specs/per-app-overrides.md` — read it before starting.

## Global Constraints

- Build: `swift build --arch arm64` (arm64 only; never add x86_64).
- Tests: `swift test` — Swift Testing (`import Testing`, `@Test`, `#expect`), never XCTest.
- Zero warnings in our targets; strict concurrency is on.
- No .xcodeproj — SwiftPM only.
- Dependency rule: `TextInjector` target must NOT import AppKit or app-layer code. All AppKit (NSOpenPanel, NSWorkspace, NSImage) stays in `FabulousApp`.
- Run `swift build`/`swift test` from the repo root (never cd into .build/checkouts).
- Commit after every task.

---

### Task 1: `AppOverride` type + merge initializer (TextInjector target)

**Files:**
- Create: `Sources/TextInjector/AppOverride.swift`
- Test: `Tests/TextInjectorTests/AppOverrideTests.swift`

**Interfaces:**
- Consumes: `InjectionStrategy`, `StrategySelector` (both in `Sources/TextInjector/InjectionStrategy.swift`; `StrategySelector.overrides` is `public var`, `StrategySelector.defaultOverrides` is the built-in terminal map).
- Produces: `public struct AppOverride: Codable, Sendable, Equatable, Identifiable { var bundleID: String; var displayName: String; var strategy: InjectionStrategy; var id: String }` and `StrategySelector.init(userOverrides: [AppOverride])`. Tasks 2–4 rely on these exact names.

- [ ] **Step 1: Write the failing tests**

Create `Tests/TextInjectorTests/AppOverrideTests.swift`:

```swift
import Foundation
import Testing
@testable import TextInjector

@Suite("AppOverride merging")
struct AppOverrideMergeTests {
    @Test func userOverrideWinsOverBuiltIn() {
        // iTerm2 is a built-in paste override; the user forces it back to
        // axInsert — the only way to neutralize a built-in (spec).
        let selector = StrategySelector(userOverrides: [
            .init(bundleID: "com.googlecode.iterm2", displayName: "iTerm2", strategy: .axInsert)
        ])
        #expect(selector.overrides["com.googlecode.iterm2"] == .axInsert)
    }

    @Test func builtInsSurviveUnrelatedUserEntries() {
        let selector = StrategySelector(userOverrides: [
            .init(bundleID: "com.example.editor", displayName: "Editor", strategy: .keystrokes)
        ])
        #expect(selector.overrides["com.apple.Terminal"] == .paste)
        #expect(selector.overrides["com.example.editor"] == .keystrokes)
    }

    @Test func emptyUserListYieldsBuiltInsExactly() {
        // Deleting the last user row reverts to stock behavior.
        #expect(
            StrategySelector(userOverrides: []).overrides
                == StrategySelector.defaultOverrides
        )
    }

    @Test func laterDuplicateWins() {
        let selector = StrategySelector(userOverrides: [
            .init(bundleID: "com.example.app", displayName: "App", strategy: .paste),
            .init(bundleID: "com.example.app", displayName: "App", strategy: .keystrokes),
        ])
        #expect(selector.overrides["com.example.app"] == .keystrokes)
    }

    @Test func selectionUsesMergedUserOverride() {
        // End to end through select(for:): override sets the chain START;
        // fallback below it still applies.
        let selector = StrategySelector(userOverrides: [
            .init(bundleID: "com.example.editor", displayName: "Editor", strategy: .paste)
        ])
        let context = InjectionContext(
            frontmostBundleID: "com.example.editor",
            secureInputActive: false,
            accessibilityTrusted: true
        )
        #expect(selector.select(for: context) == .attempt(chain: [.paste, .keystrokes]))
    }
}

@Suite("AppOverride codec")
struct AppOverrideCodecTests {
    @Test func roundTrips() throws {
        let entries = [
            AppOverride(bundleID: "com.example.a", displayName: "A", strategy: .axInsert),
            AppOverride(bundleID: "com.example.b", displayName: "B", strategy: .paste),
        ]
        let data = try JSONEncoder().encode(entries)
        let decoded = try JSONDecoder().decode([AppOverride].self, from: data)
        #expect(decoded == entries)
    }

    @Test func corruptBlobDecodesToNil() {
        // SettingsStore falls back to [] via try? — garbage must not trap.
        let garbage = Data("not json at all".utf8)
        #expect((try? JSONDecoder().decode([AppOverride].self, from: garbage)) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppOverride`
Expected: compile FAILURE — `cannot find 'AppOverride' in scope` / no `init(userOverrides:)`.

- [ ] **Step 3: Write the implementation**

Create `Sources/TextInjector/AppOverride.swift`:

```swift
import Foundation

/// A user-configured injection override for one app: which strategy the
/// chain starts at while that app is frontmost. Persisted by the app
/// layer; layered over `StrategySelector.defaultOverrides` (user wins).
public struct AppOverride: Codable, Sendable, Equatable, Identifiable {
    public var bundleID: String
    /// Persisted so the settings row still renders after the app is
    /// uninstalled — icons can fall back to a generic one, names can't.
    public var displayName: String
    public var strategy: InjectionStrategy

    public var id: String { bundleID }

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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppOverride`
Expected: 7 tests PASS. Then `swift build --arch arm64` — zero warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources/TextInjector/AppOverride.swift Tests/TextInjectorTests/AppOverrideTests.swift
git commit -m "feat: AppOverride type + user-over-builtin merge init for StrategySelector"
```

---

### Task 2: SettingsStore persistence + mutable injector selector

**Files:**
- Modify: `Sources/FabulousApp/SettingsStore.swift` (keys enum ~line 12, callbacks ~line 27, properties after `replacementEntries` ~line 100, init ~line 143)
- Modify: `Sources/TextInjector/TextInjector.swift:17` (`private let selector` → `public var selector`)

**Interfaces:**
- Consumes: `AppOverride` from Task 1.
- Produces: `SettingsStore.appOverrideEntries: [AppOverride]`, `SettingsStore.onAppOverridesChanged: (() -> Void)?`, `TextInjector.selector: StrategySelector` (settable). Tasks 3–4 rely on these exact names.

No unit tests: `FabulousApp` is an executable target no test imports (the merge logic itself was tested in Task 1). Verification is a clean build.

- [ ] **Step 1: Make the injector's selector mutable**

In `Sources/TextInjector/TextInjector.swift`, change:

```swift
    private let selector: StrategySelector
```

to:

```swift
    /// Swappable so the app layer can apply per-app overrides when the
    /// user edits them — the injector itself is long-lived (a pending
    /// clipboard restoreTask must survive settings changes).
    public var selector: StrategySelector
```

- [ ] **Step 2: Add the persisted property to SettingsStore**

In `Sources/FabulousApp/SettingsStore.swift`:

Add to the imports (top of file, alphabetical):

```swift
import TextInjector
```

Add to `Keys`:

```swift
        static let appOverrideEntries = "appOverrideEntries"
```

Add next to the other callbacks:

```swift
    @ObservationIgnored var onAppOverridesChanged: (() -> Void)?
```

Add the property after `replacementEntries` (same pattern):

```swift
    /// Per-app injection overrides, layered over the built-in terminal
    /// defaults by the AppController — user wins on the same bundle ID.
    var appOverrideEntries: [AppOverride] {
        didSet {
            guard appOverrideEntries != oldValue else { return }
            if let data = try? JSONEncoder().encode(appOverrideEntries) {
                defaults.set(data, forKey: Keys.appOverrideEntries)
            }
            onAppOverridesChanged?()
        }
    }
```

Add to `init`, after the `replacementEntries` line:

```swift
        appOverrideEntries = defaults.data(forKey: Keys.appOverrideEntries)
            .flatMap { try? JSONDecoder().decode([AppOverride].self, from: $0) }
            ?? []
```

- [ ] **Step 3: Build clean**

Run: `swift build --arch arm64`
Expected: success, zero warnings. Run `swift test` — everything still green.

- [ ] **Step 4: Commit**

```bash
git add Sources/FabulousApp/SettingsStore.swift Sources/TextInjector/TextInjector.swift
git commit -m "feat: persist per-app injection overrides; make injector selector swappable"
```

---

### Task 3: AppController wiring

**Files:**
- Modify: `Sources/FabulousApp/AppController.swift` (callback block ~line 118 next to `onReplacementsChanged`; new private method near `rebuildPostProcessor`)

**Interfaces:**
- Consumes: `SettingsStore.appOverrideEntries`, `onAppOverridesChanged` (Task 2), `StrategySelector(userOverrides:)` (Task 1), `injector` property (`private let injector = TextInjector()` at `AppController.swift:41`).
- Produces: overrides take effect at startup and immediately on every settings edit. Nothing downstream consumes new API.

- [ ] **Step 1: Wire the callback and startup application**

In `AppController.swift`, next to the existing `settings.onReplacementsChanged` line (~118), add:

```swift
        settings.onAppOverridesChanged = { [weak self] in self?.applyInjectionOverrides() }
```

Immediately after the callback-wiring block in the same init/setup flow (same place where other initial state is applied), add a call:

```swift
        applyInjectionOverrides()
```

Add the method near `rebuildPostProcessor()`:

```swift
    /// Pushes the current per-app overrides into the injector. The
    /// injector instance is deliberately kept — recreating it would drop
    /// a pending clipboard restore.
    private func applyInjectionOverrides() {
        injector.selector = StrategySelector(userOverrides: settings.appOverrideEntries)
    }
```

`AppController.swift` already has `import TextInjector` (line 8) — no import change.

- [ ] **Step 2: Build + full test run**

Run: `swift build --arch arm64 && swift test`
Expected: clean build, zero warnings, all tests pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/FabulousApp/AppController.swift
git commit -m "feat: apply per-app injection overrides at startup and on change"
```

---

### Task 4: "Apps" settings tab

**Files:**
- Modify: `Sources/FabulousApp/SettingsView.swift`:
  - imports (top of file)
  - `SettingsSection` enum (~line 20): new case `apps` between `replacements` and `history`, with `title`/`symbol`
  - `detailView` switch (~line 74): new case
  - new `AppsSettingsPane` view after the `ReplacementsSettingsPane` block (~line 455)

**Interfaces:**
- Consumes: `store.appOverrideEntries` (Task 2), `AppOverride`, `InjectionStrategy`, `StrategySelector.defaultOverrides` (Task 1 / existing).
- Produces: UI only; nothing downstream.

- [ ] **Step 1: Imports and section case**

In `SettingsView.swift`, add to imports (keep alphabetical):

```swift
import AppKit
import TextInjector
import UniformTypeIdentifiers
```

Change the `SettingsSection` enum to:

```swift
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, models, replacements, apps, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .models: "Models"
        case .replacements: "Replacements"
        case .apps: "Apps"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .models: "brain"
        case .replacements: "character.cursor.ibeam"
        case .apps: "app"
        case .history: "clock.arrow.circlepath"
        }
    }
}
```

Add to the `detailView` switch:

```swift
        case .apps:
            AppsSettingsPane(store: store)
```

- [ ] **Step 2: Add the pane**

Insert after the `ReplacementsSettingsPane` struct:

```swift
// MARK: - Apps

/// Per-app injection overrides: which strategy the chain starts at for a
/// given frontmost app. Built-in terminal defaults are shown greyed; a
/// user entry on the same bundle ID shadows the built-in (that's also how
/// a built-in is "undone" — shadow it with Accessibility insert).
private struct AppsSettingsPane: View {
    @Bindable var store: SettingsStore

    @Environment(\.theme) private var theme

    /// One list row — built-in default or user override. A user entry on
    /// a built-in bundle ID replaces the built-in row.
    private struct Row: Identifiable {
        let bundleID: String
        let displayName: String
        let strategy: InjectionStrategy
        let isUserEntry: Bool
        var id: String { bundleID }
    }

    /// Display names for the built-ins; NSWorkspace can't name apps that
    /// aren't installed, and bundle IDs are ugly.
    private static let builtInNames: [String: String] = [
        "com.apple.Terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm2",
        "dev.warp.Warp-Stable": "Warp",
        "com.github.wez.wezterm": "WezTerm",
        "net.kovidgoyal.kitty": "kitty",
        "org.alacritty": "Alacritty",
    ]

    private var rows: [Row] {
        var byID: [String: Row] = [:]
        for (bundleID, strategy) in StrategySelector.defaultOverrides {
            byID[bundleID] = Row(
                bundleID: bundleID,
                displayName: Self.builtInNames[bundleID] ?? bundleID,
                strategy: strategy,
                isUserEntry: false
            )
        }
        for entry in store.appOverrideEntries {
            byID[entry.bundleID] = Row(
                bundleID: entry.bundleID,
                displayName: entry.displayName,
                strategy: entry.strategy,
                isUserEntry: true
            )
        }
        return byID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending
        }
    }

    var body: some View {
        Form {
            Section {
                Text("Choose which injection method fabulous tries first in a specific app. If that method fails, the usual fallbacks still apply. Built-in rows cover terminals that mishandle direct insertion; change their method to override them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Overrides") {
                ForEach(rows) { row in
                    rowView(row)
                }
                Button {
                    addApp()
                } label: {
                    Label("Add App…", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.paper)
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: icon(for: row.bundleID))
                .resizable()
                .frame(width: 20, height: 20)
            Text(row.displayName)
                .foregroundStyle(row.isUserEntry ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            if !row.isUserEntry {
                Text("built-in")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.accent.opacity(0.15)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: strategyBinding(for: row)) {
                ForEach(InjectionStrategy.allCases, id: \.self) { strategy in
                    Text(displayName(of: strategy)).tag(strategy)
                }
            }
            .labelsHidden()
            .fixedSize()
            Button {
                store.appOverrideEntries.removeAll { $0.bundleID == row.bundleID }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!row.isUserEntry)
            .help(row.isUserEntry
                ? "Remove override"
                : "Built-in — change its method to shadow it")
        }
    }

    /// Any picker change writes a user entry, even one equal to the
    /// built-in's value — one uniform rule, and the result is deletable.
    private func strategyBinding(for row: Row) -> Binding<InjectionStrategy> {
        Binding(
            get: { row.strategy },
            set: { newValue in
                if let index = store.appOverrideEntries.firstIndex(
                    where: { $0.bundleID == row.bundleID }
                ) {
                    store.appOverrideEntries[index].strategy = newValue
                } else {
                    store.appOverrideEntries.append(.init(
                        bundleID: row.bundleID,
                        displayName: row.displayName,
                        strategy: newValue
                    ))
                }
            }
        )
    }

    private func displayName(of strategy: InjectionStrategy) -> String {
        switch strategy {
        case .axInsert: "Accessibility insert"
        case .paste: "Paste"
        case .keystrokes: "Keystrokes"
        }
    }

    private func icon(for bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        // Starting point only — system apps live in /System/Applications,
        // so the user can browse anywhere.
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an app to set an injection method for"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier
        else { return }  // bundle without an identifier: ignore (spec)

        // Already listed (user row or built-in)? The row is on screen —
        // no duplicate is created.
        guard !store.appOverrideEntries.contains(where: { $0.bundleID == bundleID }),
              StrategySelector.defaultOverrides[bundleID] == nil
        else { return }

        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        // Paste: the most common reason to override at all.
        store.appOverrideEntries.append(.init(
            bundleID: bundleID, displayName: name, strategy: .paste
        ))
    }
}
```

Note the `AnyShapeStyle` wrapper on the name's `foregroundStyle` — the two branches have different concrete types and SwiftUI needs the erasure to compile.

- [ ] **Step 3: Build clean**

Run: `swift build --arch arm64`
Expected: success, zero warnings (watch for unused-import or Sendable warnings; fix before committing).

- [ ] **Step 4: Manual smoke test**

```bash
CONFIG=debug scripts/build.sh && open build/fabulous.app
```

(If `scripts/build.sh` fails with `errSecInternalComponent`, the dev keychain locked: `security unlock-keychain -p fabulous-dev-local ~/Library/Keychains/fabulous-dev.keychain-db` and retry.)

Checklist — settings window → Apps tab:
- Six built-in terminal rows visible, greyed, "built-in" badge, trash disabled, sorted by name.
- Change iTerm2's popup to "Accessibility insert" → row turns full-color (now a user entry); trash enabled; delete it → reverts to greyed built-in Paste.
- Add App… → panel opens at /Applications, can navigate to /System/Applications; pick e.g. Notes → row appears with icon + name + Paste.
- Pick Notes again → no duplicate row.
- Quit and relaunch app → rows persist.
- Dictate into the added app → delivery uses the overridden method (menu "Inject" stats line shows the method used).

- [ ] **Step 5: Commit**

```bash
git add Sources/FabulousApp/SettingsView.swift
git commit -m "feat: Apps settings tab for per-app injection overrides"
```

---

### Task 5: Docs

**Files:**
- Modify: `CLAUDE.md` (State/roadmap section: remove "per-app injection override settings UI" from "Not yet built", add one line to Done citing `docs/specs/per-app-overrides.md`)
- Modify: `docs/architecture.md:154-157` (the "Per-app overrides start the chain lower" sentence)

- [ ] **Step 1: Update CLAUDE.md roadmap**

In the "Not yet built" paragraph, delete `per-app injection override settings UI`. In the Done list, append:

```
per-app injection overrides (docs/specs/per-app-overrides.md): Apps
settings tab, AppOverride user entries layered over built-in terminal
defaults (user wins, delete reverts), injector selector swapped live.
```

- [ ] **Step 2: Update architecture.md**

In `docs/architecture.md` (~line 154), change:

```
Per-app overrides start the chain
lower (terminals default to paste — AX insertion into terminal emulators is
unreliable); the chain never promotes back upward.
```

to:

```
Per-app overrides start the chain
lower (terminals default to paste — AX insertion into terminal emulators is
unreliable); users add their own in Settings → Apps, layered over the
built-ins (user wins on the same bundle ID). The chain never promotes back
upward.
```

- [ ] **Step 3: Full verification**

Run: `swift build --arch arm64 && swift test`
Expected: clean build, zero warnings, all tests green.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/architecture.md
git commit -m "docs: per-app injection overrides shipped — roadmap + architecture notes"
```
