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

In: async clipboard restore in `TextInjector`, per-dictation winning
strategy in `DictationMetrics`, persistence, menu surfacing.

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

The pre-⌘V path is unchanged: save clipboard, write transcript, 50 ms
settle, post ⌘V. Failure to post still restores synchronously and
returns `false`.

Effect on metrics: `delivery` now ends when the text appears (⌘V posted),
not after bookkeeping. Expected paste delivery ~370 ms → ~60 ms, with no
behavior change visible to the target app.

### 2. Strategy in metrics (FabCore + FabulousApp)

`InjectionStrategy` moves from `TextInjector` to `FabCore` unchanged
(String-backed pure value enum — FabCore's charter, same precedent as
`LLMCleanupOutcome`). `TextInjector` already depends on FabCore; only
import lines change elsewhere.

`DictationMetrics` gains:

- `strategy: InjectionStrategy?` — the strategy that delivered the text;
  `nil` when delivery went through the safety net (focus change, secure
  input, accessibility revoked, all strategies failed).

`AppController.deliver` returns the winning strategy (`inject()` already
returns it — today discarded) or `nil` on any safety-net path;
`finishRecording` threads it into the metrics row. `logLine` appends
` via=paste` when strategy is non-nil, ` via=safetyNet` otherwise.

### 3. Persistence (HistoryStore)

Migration `v6-metrics-strategy` on `dictationMetrics`:

- `strategy TEXT` (nullable; `NULL` = safety net **or** pre-migration row)

Same lifecycle as existing metrics columns: numbers/labels only,
independent of the history toggle, survives Clear History, cap-pruned
with the table.

### 4. Menu (FabulousApp)

One line beside the existing per-engine ASR and cleanup stats, computed
from the newest 500 rows where `strategy IS NOT NULL`:

```
Inject ax 62% 8 ms · paste 30% 58 ms · keys 8% 0.2 s
```

Per strategy: share of dictations + delivery p50. Strategies with zero
rows are omitted; the whole line hides when no qualifying rows exist.
Restricting to `strategy IS NOT NULL` also keeps pre-change rows (whose
`deliveryMs` includes the old 300 ms restore wait) out of the
percentiles — only post-change measurements mix.

Plumbing mirrors `cleanupStats`: `HistoryStore.strategyStats(limit: 500)`
returns per-strategy count + p50 `deliveryMs`;
`StatusItemController.setStrategyStats(String?)` (nil hides). Refreshed at
the same points as the other stats lines: after `persistMetrics` and in
`refreshLatencyStats`.

## Error handling

No new failure modes. Restore-task cancellation and the changeCount guard
both degrade to "clipboard keeps newest content" — never to lost text.
Safety-net paths are untouched and now labeled in metrics instead of
invisible.

## Testing

- `StrategySelector` tests unchanged (pure logic untouched).
- `DictationMetrics`: `logLine` via-segment; strategy round-trip.
- HistoryStore: `v6` migration + roundtrip of nullable `strategy`;
  `strategyStats` percentile/share math including NULL exclusion.
- Menu formatting: share + p50 string, omission of empty strategies,
  hidden when no rows.
- PipelineTests are untouched: they end at the `StrategySelector`
  decision and never reach `deliver`/metrics. The deliver → metrics
  threading (non-nil strategy on injection, nil on safety net) has no
  fake-injector seam today; it is verified in dogfood via the new
  `via=` segment in the log line rather than by adding a seam for one
  assertion.
- Async restore is manual-verified during dogfood (real NSPasteboard +
  target app; not meaningfully unit-testable): paste lands, clipboard
  restores after ~300 ms, rapid double dictation keeps the second
  transcript's paste intact.

## Success criteria

Paste-path delivery p50 drops from ~370 ms to well under 100 ms in the
menu stats. After a week of dogfood: strategy share per the menu line
answers whether axInsert fails in editors/browsers — and therefore whether
an AX investigation or per-app overrides are the next latency work.
