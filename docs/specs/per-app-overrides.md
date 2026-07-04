# Per-App Injection Overrides

**Date:** 2026-07-04
**Status:** Approved design, pending implementation

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

The merge helper is a small pure function in the app layer.

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
- **+** button → NSOpenPanel rooted at /Applications, filtered to `.app`;
  bundle ID + display name read from the chosen bundle. Picking an app
  that already has a row selects that row instead of duplicating. New
  rows default to **Paste** (the most common reason to override).
- **−** button deletes the selected user row; disabled for built-in rows.
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

All pure, no AppKit:

- Merge semantics: user wins over built-in; removing a user entry
  resurfaces the built-in.
- `StrategySelector.select` with a merged map: overridden app starts at
  the chosen strategy; unlisted app gets the axInsert chain.
- `AppOverride` JSON round-trip; corrupt blob → empty list.
- Existing StrategySelector tests untouched (no selector logic change).

UI is exercised manually (consistent with the other settings tabs).
