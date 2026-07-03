# Injection latency: async clipboard restore + strategy telemetry

*Designed 2026-07-03. Follow-up to the phase-5 A/B finding that
delivery/injection ≈ 370 ms is the next latency bottleneck.*

## Problem

The paste strategy in `TextInjector.attemptPaste` sleeps 50 ms before
synthesizing ⌘V and 300 ms after it, before restoring the saved clipboard.
Both sleeps sit on the critical path: `AppController.deliver` awaits
`inject`, and `deliveredAt` is stamped after the restore. So every paste
dictation reports ~370 ms of delivery, of which 300 ms is clipboard
bookkeeping that happens *after* the text is already visible in the target
app.

Measured delivery ≈ 370 ms matches the paste path, which means paste — not
axInsert — is winning most dictations. Usage is mixed across terminals,
editors, and browsers, and metrics don't record which strategy ran, so we
can't tell whether that's the terminal overrides working as designed or
axInsert failing in apps where it should work.

Decision: fix the one unambiguous win now (restore off the critical path),
and add strategy telemetry so the next dogfood round shows where axInsert
actually fails. No strategy-chain or AX changes until that data exists.

## Scope

In: async clipboard restore in `TextInjector`, per-dictation delivery
method (winning strategy or safety net) in `DictationMetrics`,
persistence, menu surfacing.

Out: shrinking the 50 ms pre-⌘V settle (dropped pastes are worse than
50 ms; revisit with data), axInsert failure investigation, strategy-chain
or override changes, keystroke-path tuning (5 ms chunk sleeps stay),
per-app override settings UI.

## Design

### 1. Async clipboard restore (TextInjector)

`attemptPaste` returns `true` immediately after the ⌘V events post. The
restore moves to a stored task:

- `TextInjector` holds `private var restoreTask: Task<Void, Never>?`
  (class is `@MainActor`, so mutation is safe).
- After posting ⌘V: `restoreTask = Task { … }` — sleep 300 ms, then
  restore `saved` only if `pasteboard.changeCount == ourChangeCount`
  (same guard as today). Cancellation aborts the sleep and skips the
  restore.
- `inject()` cancels any pending `restoreTask` at entry. A second
  dictation within the 300 ms window therefore skips dictation-1's
  restore, and the clipboard keeps the newest content — same class of
  quirk the synchronous code has (a user copy inside the window wins);
  no transcript is ever lost.
- Accepted quirk: quitting the app inside the 300 ms window also skips
  the restore (the task dies with the process). Negligible — the old
  code merely shrank that window to zero, and the clipboard holds the
  transcript, not garbage.

The pre-⌘V path is unchanged: save clipboard, write transcript, 50 ms
settle, post ⌘V. Failure to post still restores synchronously and
returns `false`.

Effect on metrics: `delivery` now ends when the text appears (⌘V posted),
not after bookkeeping. Expected paste delivery ~370 ms → ~60 ms, with no
behavior change visible to the target app.

### 2. Delivery method in metrics (FabCore + FabulousApp)

FabCore gains the metrics vocabulary (same precedent as
`LLMCleanupOutcome`):

```swift
public enum DeliveryMethod: String, Sendable, Codable, Equatable {
    case axInsert, paste, keystrokes  // raw values match InjectionStrategy
    case safetyNet                    // clipboard fallback, any reason
}
```

`InjectionStrategy` stays in `TextInjector` — no module churn; the two
vocabularies are decoupled on purpose (one is "how to inject", the other
is "how the text got delivered"). AppController maps the winner via
`DeliveryMethod(rawValue: strategy.rawValue)`.

A distinct `safetyNet` case — rather than `nil` — matters because the
safety-net rate is precisely the failure signal this telemetry exists to
catch; folding it into NULL would make it indistinguishable from
pre-migration rows.

`DictationMetrics` gains `delivery method`:

- `deliveryMethod: DeliveryMethod` — non-optional; every delivered
  dictation has one (focus change, secure input, accessibility revoked,
  and all-strategies-failed are all `.safetyNet`).

`AppController.deliver` returns the method (`inject()` already returns
the winning strategy — today discarded); `finishRecording` threads it
into the metrics row. `logLine` appends ` via=paste` / ` via=safetyNet`.

### 3. Persistence (HistoryStore)

Migration `v6-metrics-delivery-method` on `dictationMetrics`:

- `deliveryMethod TEXT` (nullable in SQL; `NULL` = pre-migration row
  only — every new row writes a non-NULL value)

Same lifecycle as existing metrics columns: numbers/labels only,
independent of the history toggle, survives Clear History, cap-pruned
with the table.

### 4. Menu (FabulousApp)

One line beside the existing per-engine ASR and cleanup stats, computed
from the newest 500 rows where `deliveryMethod IS NOT NULL`:

```
Inject ax 60% 8 ms · paste 29% 58 ms · keys 8% 0.2 s · net 3%
```

Per method: share of dictations + delivery p50 (`safetyNet` shows share
only — its "delivery" is a clipboard write, not comparable). Methods with
zero rows are omitted; the whole line hides when no qualifying rows
exist. Restricting to `deliveryMethod IS NOT NULL` also keeps
pre-change rows (whose `deliveryMs` includes the old 300 ms restore
wait) out of the percentiles — only post-change measurements mix.

Plumbing mirrors `cleanupStats`: `HistoryStore.deliveryStats(limit: 500)`
returns per-method count + p50 `deliveryMs`;
`StatusItemController.setDeliveryStats(String?)` (nil hides). Refreshed at
the same points as the other stats lines: after `persistMetrics` and in
`refreshLatencyStats`.

## Error handling

No new failure modes. Restore-task cancellation and the changeCount guard
both degrade to "clipboard keeps newest content" — never to lost text.
Safety-net paths are untouched and now labeled in metrics instead of
invisible.

## Testing

- `StrategySelector` tests unchanged (pure logic untouched).
- `DeliveryMethod`: mapping from every `InjectionStrategy` case (raw
  values stay aligned — a case rename in either enum fails this test).
- `DictationMetrics`: `logLine` via-segment; deliveryMethod round-trip.
- HistoryStore: `v6` migration + roundtrip of `deliveryMethod`;
  `deliveryStats` percentile/share math including NULL (pre-migration
  row) exclusion.
- Menu formatting: share + p50 string, safetyNet share-only rendering,
  omission of empty methods, hidden when no rows.
- PipelineTests are untouched: they end at the `StrategySelector`
  decision and never reach `deliver`/metrics. The deliver → metrics
  threading (strategy on injection, `.safetyNet` on fallback) has no
  fake-injector seam today; it is verified in dogfood via the new
  `via=` segment in the log line rather than by adding a seam for one
  assertion.
- Async restore is manual-verified during dogfood (real NSPasteboard +
  target app; not meaningfully unit-testable): paste lands, clipboard
  restores after ~300 ms, rapid double dictation keeps the second
  transcript's paste intact.

## Success criteria

Paste-path delivery p50 drops from ~370 ms to well under 100 ms in the
menu stats. After a week of dogfood: method share per the menu line
answers whether axInsert fails in editors/browsers — and the safety-net
rate is visible for the first time — so the next latency work (AX
investigation, per-app overrides, or nothing) is decided from data.
