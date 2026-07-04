# Per-App Injection Overrides

**Date:** 2026-07-04
**Status:** Shipped 2026-07-04

## Motivation

No acute breakage today — this is the escape hatch. When a future app
misbehaves with the default injection chain (AX reports success without
inserting, paste triggers an app shortcut, etc.), the user fixes it in
Settings instead of waiting for a code change. Closes the "per-app
injection override settings UI" roadmap item.

## What an override does

An override sets the **starting strategy** of the injection chain for one
app, identified by bundle ID. The normal fallback below that start still
applies (`StrategySelector.chain(startingAt:)` is unchanged):

- `axInsert` → axInsert, paste, keystrokes (the default for unlisted apps)
- `paste` → paste, keystrokes
- `keystrokes` → keystrokes only

Out of scope (deliberately): pinning a single strategy with no fallback,
per-app "never inject / clipboard only" mode, per-app cleanup toggles,
metrics changes (DeliveryMethod telemetry already records the outcome).

## Data model

New value type in the `TextInjector` target (next to `InjectionStrategy`;
FabCore never sees it):

```swift
public struct AppOverride: Codable, Sendable, Equatable {
    public var bundleID: String
    public var displayName: String   // persisted so the row survives uninstall
    public var strategy: InjectionStrategy
}
```

Persistence follows the replacements precedent exactly:
`SettingsStore.appOverrideEntries: [AppOverride]` stored as a JSON blob in
UserDefaults, with an `onAppOverridesChanged` callback. Corrupt or missing
data decodes to an empty list — never a crash. (Whole-array decode; no
per-entry tolerance. `InjectionStrategy` raw values are stable.)

### Layering semantics

Effective override map = `StrategySelector.defaultOverrides` merged with
user entries, **user wins** on the same bundle ID. Built-ins stay
untouchable underneath: deleting a user row that shadows a built-in
reverts to the built-in; deleting any other user row reverts to the
default auto chain. Built-ins added in future fabulous releases surface
automatically because they are never copied into user data.

The merge helper lives in the `TextInjector` target (a `StrategySelector`
convenience, e.g. `StrategySelector(userOverrides:)` layering user entries
over `defaultOverrides`) — NOT the app layer: `FabulousApp` is an
executable target no test imports, and merge semantics must be unit
tested.

Reverting a built-in: built-in rows cannot be deleted, so the way to
neutralize one (e.g. make iTerm2 try axInsert again) is to shadow it with
an explicit `axInsert` override. That is why the popup offers all three
strategies on every row.

## Settings UI — new "Apps" tab

New tab after Replacements, styled like the existing tabs (PaperTheme).

- Table columns: app icon | display name | strategy popup
  ("Accessibility insert" / "Paste" / "Keystrokes").
- Icon fetched live from NSWorkspace by bundle ID; generic app icon when
  the app is not installed.
- Two row kinds in one list:
  - **Built-in rows** (the six terminals in
    `StrategySelector.defaultOverrides`): greyed, "built-in" badge, popup
    enabled. Changing the popup creates a user entry shadowing the
    built-in.
  - **User rows**: full color, deletable.
- Rows sorted by display name (built-ins and user rows interleaved).
- **+** button → NSOpenPanel filtered to `.app`, initial directory
  /Applications but free to browse anywhere (system apps live in
  /System/Applications); bundle ID + display name read from the chosen
  bundle. A bundle with no bundle identifier is ignored. Picking an app
  that already has a row selects that row instead of duplicating. New
  rows default to **Paste** (the most common reason to override).
- Each user row has a trash button; disabled on built-in rows. (Built as per-row buttons — the grouped Form has no row selection, so a selection-based − button was dropped.)
- Changing any row's popup always writes a user entry, even if the chosen
  value equals the built-in's — one uniform rule, and the resulting user
  row is deletable.
- Picking an app that already has a row is a no-op — the row is already on screen; no duplicate is created.
- Footer caption, one line: an override picks the *first* strategy tried;
  fallback to the others still applies.

## Wiring

- `TextInjector.selector` becomes `public var` (currently `let` set at
  init).
- AppController, at startup and on `onAppOverridesChanged`: rebuild
  `StrategySelector(overrides: merged)` and assign to the long-lived
  injector. The injector instance is **never recreated** — the pending
  clipboard `restoreTask` invariant stays intact.
- Refusal checks (secure input, missing Accessibility) run before the
  override lookup, unchanged.

## Testing

All pure, no AppKit, in `Tests/TextInjectorTests`:

- Merge semantics: user wins over built-in; removing a user entry
  resurfaces the built-in.
- `StrategySelector.select` with a merged map: overridden app starts at
  the chosen strategy; unlisted app gets the axInsert chain.
- `AppOverride` JSON round-trip; corrupt blob → empty list.
- Existing StrategySelector tests untouched (no selector logic change).

UI is exercised manually (consistent with the other settings tabs).
