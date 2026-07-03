# LLM cleanup observability + session prewarm

*Designed 2026-07-03. Follow-up to [llm-post-processing.md](llm-post-processing.md).*

## Problem

Dogfooding the LLM cleanup stage says "latency feels bad", but the feeling is
unmeasured: cleanup time is lumped into `DictationMetrics.postProcessing`
together with replacements, and the processor swallows failures internally, so
a fallback (timeout, guardrail refusal, rejected empty output) is
indistinguishable from a no-op from the outside. On top of that, every
dictation pays `LanguageModelSession` creation plus instructions
prompt-processing *after* the user stops speaking — dead time that could
overlap with recording.

Decision made up front: **measure first**. No latency budget is set until a
week of dogfood data exists. This spec adds the measurement and the one
latency win that is free and invariant-preserving (prewarming the session
during recording). Prompt work (anti-echo few-shots) waits for data showing
echo is a real problem.

## Scope

In: per-dictation cleanup timing + outcome in `DictationMetrics`, persistence,
menu surfacing, session prewarm at record-start.

Out: prompt changes, latency budget enforcement, timeout counters / failure-
reason columns / debug panel (add only if dogfood data demands them).

Accepted gap: a whole-utterance "scratch that" (cleanup legitimately empties
the transcript) exits at the existing empty-text guard before metrics are
recorded, so no row is written for it. Persisting one would pollute engine
latency percentiles with non-delivered dictations (no delivery stage, no
meaningful total). Rare path; revisit only if dogfood shows it matters.

## Design

### 1. Metrics model (FabCore)

`DictationMetrics` gains two fields:

- `llmCleanup: Duration` — wall time of the LLM stage; `.zero` when cleanup
  is off.
- `llmOutcome: LLMCleanupOutcome` — `off | unchanged | changed | fellBack`.

`LLMCleanupOutcome` is a `String`-backed enum in FabCore (persisted raw value,
readable in sqlite). `postProcessing` reverts to meaning replacements-only;
AppController times the two stages separately around the two calls it already
makes. `logLine` appends `llm=0.42 s (changed)` when outcome ≠ `off`.
`menuSummary` is unchanged — `total` already includes cleanup.

### 2. Outcome reporting (PostProcessing)

`ContextualTextPostProcessor` gains:

```swift
struct CleanupReport { let text: String; let outcome: LLMCleanupOutcome }
func cleanup(_ text: String) async -> CleanupReport
```

`process` remains (protocol conformance, never-lose-text floor), implemented
as `cleanup(text).text`. AppController switches to `cleanup`. Outcome mapping
inside `FoundationModelPostProcessor`:

- empty input (early return) → `unchanged`
- throw / timeout → `fellBack`, raw text
- empty output, raw does **not** end with "scratch that" → `fellBack`, raw text
- empty output, raw ends with "scratch that" → `changed`, empty text
- output equals raw (post edge-space strip) → `unchanged`
- otherwise → `changed`

The existing invariant is untouched: every non-`changed`/`unchanged` path
returns the raw transcript.

AppController stops computing `cleaned != rawText` itself; the history
`rawText` column keys off `report.outcome == .changed`, so history and
metrics cannot disagree about whether cleanup changed the text.

### 3. Persistence (HistoryStore)

Migration `v5-metrics-llm` on `dictationMetrics` (`v4-transcript-rawtext`
already exists; GRDB migration names are append-only and unique):

- `llmMs REAL NOT NULL DEFAULT 0`
- `llmOutcome TEXT NOT NULL DEFAULT 'off'`

Same lifecycle as existing metrics: numbers only, independent of the history
toggle, survives Clear History, cap-pruned with the table.

### 4. Menu (FabulousApp)

One line beside the per-engine ASR p50/p90 stats, computed from rows where
`llmOutcome != 'off'`:

```
Cleanup p50 0.38 s · p90 0.71 s · fell back 2/41
```

Hidden when no qualifying rows exist. "Fell back" count is the dogfood signal
for both reliability and (via `unchanged` rates in the table) the suspected
echo problem.

Plumbing mirrors the existing stats line: `HistoryStore.cleanupStats(limit:
500)` — engine-agnostic, newest 500 rows with `llmOutcome != 'off'`, returns
p50/p90 `llmMs`, `fellBack` count, and sample count —
plus `StatusItemController.setCleanupStats(String?)` (nil hides). Refreshed
at the same two points as the latency line: after `persistMetrics` and in
`refreshLatencyStats`.

### 5. Session prewarm (PostProcessing + AppController)

Two seams grow, both with protocol-extension default no-ops so existing
fakes and conformers compile unchanged:

- `ContextualTextPostProcessor` gains `func prepare() async`.
  `FoundationModelPostProcessor` implements it by assembling the
  instructions (vocabulary + current app context, same builder call as
  `cleanup`) and forwarding to the requester. AppController only ever talks
  to the processor.
- `LanguageModelRequesting` gains `func prepare(instructions: String) async`.

`FoundationModelRequester` becomes an actor holding
`prepared: (instructions: String, session: LanguageModelSession)?`:

- `prepare(instructions:)` builds `LanguageModelSession(instructions:)` and
  calls `session.prewarm()`, so model residency and the instructions prefix
  warm while the user is still speaking. Failures are logged and swallowed —
  prewarm is opportunistic.
- `cleanup(instructions:transcript:)` consumes the prepared session only when
  the instructions match exactly; otherwise it builds a fresh session. Either
  way `prepared` is cleared after use. One session serves at most one
  dictation — the fresh-per-dictation invariant (no context accumulation, no
  text leaking across dictations) holds by construction.

AppController, on record-start, fire-and-forget off the hot path: if
`llmProcessor` exists, `setAppContext(recordingTargetAppName())` then
`prepare()` on the processor. Staleness is harmless by design: focus change between start and
stop, a vocabulary edit mid-recording, or an Esc-cancelled recording all
produce an instructions mismatch (or an unused session) and fall back to a
fresh session silently.

## Error handling

No new failure modes reach the user. `prepare` failures degrade to today's
behavior (fresh session at cleanup time). All existing fallback paths keep
returning the raw transcript; they now additionally label themselves
`fellBack` in metrics.

## Testing

- `FoundationModelPostProcessor` outcome mapping via existing fake-requester
  seam: throwing fake → `fellBack`; echo fake → `unchanged`; empty-output fake
  with/without trailing "scratch that" → `fellBack` raw / `changed` empty;
  rewriting fake → `changed`.
- Prepared-session semantics with a recording fake: `prepare` then matching
  `cleanup` consumes the prepared session exactly once; mismatched
  instructions discard it; second `cleanup` gets a fresh session.
- `DictationMetrics.logLine` llm segment; menu percentile/fallback string.
- HistoryStore migration + roundtrip of `llmMs` / `llmOutcome`.
- Real-model prewarm delta is measured manually during dogfood (menu p50/p90
  before/after), not asserted in tests.

## Success criteria

After a week of dogfood: cleanup p50/p90 and fallback rate readable from the
menu; `unchanged` rate queryable from the table (echo signal); a decision on
the latency budget — and on whether anti-echo prompt work is needed — made
from that data.
