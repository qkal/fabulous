# Screen Context — On-Screen Vocabulary for Dictation

**Date:** 2026-07-04
**Status:** Implemented 2026-07-05

## Motivation

Dictation quality suffers exactly where it matters most: rare terms —
names, jargon, identifiers — that the user is looking at on screen while
speaking. The frontmost app's visible text is a free, highly relevant
vocabulary source. This feature harvests it at recording start and feeds
it into (a) LLM cleanup vocabulary bias and (b) SpeechAnalyzer contextual
strings, so on-screen words transcribe and correct properly.

Decisions made during brainstorming (2026-07-04):

- **AX-first, no screenshots.** Text comes from the Accessibility API
  (tree walk of the frontmost window), which uses the Accessibility grant
  we already hold. Screenshot + OCR would require the Screen Recording
  TCC permission plus macOS 15's recurring "can see your screen" nag
  dialogs — rejected for a daily-driver utility. Trade-off accepted:
  apps with poor AX exposure (some Electron apps, games, image/PDF
  content) yield little or nothing.
- **Default-on**, toggle in Settings → General to disable.
- **Both consumers**: LLM cleanup (all engines) and ASR biasing
  (SpeechAnalyzer only — see engine coverage below).

## Engine coverage

| Engine | ASR biasing | LLM cleanup vocab |
|---|---|---|
| SpeechAnalyzer | ✅ `AnalysisContext.contextualStrings` | ✅ |
| WhisperKit | ❌ deferred (see Out of scope) | ✅ |
| Parakeet | ❌ no biasing API in FluidAudio | ✅ |

The cleanup column applies only when LLM cleanup is enabled (it is
opt-in). Cleanup off + a non-biasing engine → no consumer, and the AX
walk is skipped for that dictation.

Verified against the macOS 26 SDK interface: `AnalysisContext` carries
`contextualStrings: [ContextualStringsTag: [String]]` (tag `.general`),
is passed to `SpeechAnalyzer.init(..., analysisContext:)`, and — key
find — can be updated **mid-session** via
`SpeechAnalyzer.setContext(_:) async throws`. So the streaming path
never waits for the AX walk: transcription starts immediately and the
context attaches whenever the walk finishes.

## Architecture

New SwiftPM target `ScreenReader` (feature module, depends only on
FabCore), plus pure additions to FabCore:

- `FabCore.ScreenContext` — value type: `windowTitle`,
  `terms: [String]`, `capturedAt`. (No `appName`: it already flows
  separately via `setAppContext`, and resolving it needs AppKit, which
  the reader deliberately avoids.)
- `FabCore.SalientTermExtractor` — pure function, raw harvested strings →
  salient terms. v1 heuristics (no dictionary lookup; NSSpellChecker is
  AppKit and FabCore stays AppKit-free): capitalized-mid-sentence words,
  camelCase / snake_case / dotted identifiers, tokens containing digits,
  dedupe case-insensitively, order by frequency, cap at 30.
- `ScreenReader.ScreenContextReader` — walks the focused window of a
  given pid: `AXUIElementCreateApplication(pid)` → focused/main window →
  depth-limited traversal collecting `AXValue` / `AXTitle` / static-text
  attributes; for large text areas prefer the visible portion
  (`AXVisibleCharacterRange` + `AXStringForRange`) when the element
  exposes it, falling back to the capped full value. Behind protocol `ScreenContextReading` so AppController
  tests inject a fake. Traversal core is factored as a pure function
  over an abstract node interface so depth-limit / char-cap /
  secure-field-skip logic unit-tests without live AX.

Touched existing code:

- `TranscriptionEngine` seams — deliberately additive, no churn in
  existing conformances:
  - `StreamingSession` gains `updateContext(_ terms: [String]) async`
    with a default no-op extension; only the SpeechAnalyzer session
    overrides it (calls `SpeechAnalyzer.setContext` mid-session).
  - New marker protocol `ContextBiasing` (`setContextualTerms([String])
    async`) adopted by `SpeechAnalyzerBackend` only; the batch call site
    applies it via `as?` before `transcribe`, so
    `TranscriptionBackend.transcribe` and the Whisper/Parakeet backends
    are untouched. Terms are per-dictation: set before the transcribe
    call, cleared after.
- `SpeechAnalyzerBackend` — both paths apply terms via
  `analyzer.setContext(_:)` after analyzer creation (the plain
  `init(modules:options:)` has no `analysisContext:` parameter; only
  the input-sequence convenience does). Batch terms are stored by
  `setContextualTerms` and consumed by the next `transcribe`; the
  streaming session applies `setContext` mid-session when terms arrive.
  A context rejection (throw) is logged and swallowed — never fails the
  session.
- `ContextualTextPostProcessor` — gains
  `setScreenTerms(_ terms: [String]) async` with a default no-op,
  following the existing `setAppContext` per-dictation setter pattern.
  A per-call `extraVocabulary` parameter was rejected: `prepare()`
  prewarming reuses the warmed `LanguageModelSession` only on an EXACT
  instructions match, so per-call vocabulary would silently defeat the
  prewarm. Instead, when the AX walk lands mid-recording, AppController
  calls `setScreenTerms` and then `prepare()` again — the re-warm with
  final instructions still overlaps the user speaking.
- `FoundationModelPostProcessor` — stores screen terms next to `appName`
  and builds instructions from a merged list: constructor-baked user
  vocabulary first and never truncated, case-insensitive dedupe, screen
  terms contribute at most their 30-term cap.
- `CleanupPromptBuilder` — **no signature change**; it keeps receiving
  a single merged `vocabulary` list.
- `AppController` — orchestration (see Data flow). Reuses the
  `recordingTargetPID` already captured at recording start
  (AppController.swift:417) — no second frontmost lookup. Skips the AX
  walk when no consumer exists for this dictation (LLM cleanup disabled
  AND the active engine is not `ContextBiasing`) — no wasted reads.
- `SettingsStore` — `useScreenContext: Bool`, default `true`; toggle in
  Settings → General. With
  the toggle off or an empty context the prompt is byte-identical to
  today.

## Data flow

```
hotkey press → AppController.startRecording
  ├─ audio capture starts (unchanged)
  └─ if useScreenContext && a consumer exists (cleanup on, or engine
     is ContextBiasing): spawn Task →
       ScreenContextReader.read(pid: recordingTargetPID)
         off the main actor; AXUIElementSetMessagingTimeout ≈100 ms per
         app element; whole walk time-boxed ≈1 s; harvested text capped
         ≈20k chars → SalientTermExtractor → ScreenContext
```

Consumption:

- **Streaming (SpeechAnalyzer):** session starts immediately; when the
  walk task completes, AppController calls
  `StreamingSession.updateContext`, which attaches contextual strings
  mid-session via `setContext`. The same completion hook pushes the
  terms into the cleanup processor (`setScreenTerms` + `prepare()`), so
  the warmed session is rebuilt with the final instructions while the
  user is still speaking. Walk slower than the utterance → context simply never
  attaches; no waiting, no latency.
- **Batch ASR + LLM cleanup (finishRecording):** await the walk task
  with a short timeout (≈100 ms — it is virtually always done; only
  ultra-short dictations race it). Timeout → proceed with no context.

Focus changes mid-recording: context stays pinned to the app the
dictation started in — same semantics as the injection target and the
focus-change guard. Dictating into fabulous's own settings window is not
special-cased; reading our own window is harmless.

## Privacy (hard invariants)

- Screen text lives in memory only, per dictation, discarded after
  delivery. Never written to history, never in `DictationMetrics`, never
  logged verbatim — the log line records a count only
  (`screen ctx: 12 terms`).
- The walk skips `AXSecureTextField` subtrees (passwords).
- Toggle off → the reader is never invoked; zero AX reads.
- No new TCC permission; the existing Accessibility grant covers AX
  reading. Onboarding unchanged.

## Error handling

Guiding invariant (same spirit as the injection safety net and the
cleanup no-loss rule): **screen context may only improve a dictation,
never delay it beyond the stated bounds and never fail it.**

- AX walk fails / times out / app exposes no text → empty context,
  dictation proceeds exactly as today.
- Misbehaving app hangs AX calls → per-element messaging timeout plus
  the walk time-box bound the worst case; a walk still running at
  delivery is cancelled and its result discarded.
- Garbage harvest → extractor caps and dedupe bound the damage; cleanup
  already guarantees improve-or-no-op, so bad vocabulary cannot lose
  text.
- `setContext` / `analysisContext` rejection → logged, session continues
  without biasing.

Known risk to measure while dogfooding: up to 30 heuristic terms in the
cleanup vocabulary is noisier than the user's curated list; watch for
echo/insertion regressions (the anti-echo prompt history in
llm-post-processing.md). The cap is the tuning knob.

## Testing

- `SalientTermExtractor` (FabCore tests): identifier forms (camelCase,
  snake_case, dotted), mid-sentence capitals, digit tokens, dedupe, cap,
  empty input, 20k-char blob truncation.
- Traversal core (pure, over a fake node tree): depth limit, char cap,
  secure-field skip.
- `CleanupPromptBuilder` regression: merged-vocab path produces the same
  prompt shape; empty context → byte-identical prompt to today.
- `FoundationModelPostProcessor` merge: screen terms land after user
  vocabulary, dedupe case-insensitively, empty terms leave today's
  instructions unchanged; `prepare()` after `setScreenTerms` warms a
  session that the subsequent `cleanup` actually reuses (exact
  instructions match).
- PipelineTests with a fake `ScreenContextReading`: terms flow capture →
  cleanup; toggle off → reader never called; no consumer (cleanup off +
  non-biasing engine) → reader never called; slow fake → batch path
  proceeds without context after timeout.
- Real AX walk: conditional `FAB_REAL_AX=1` test against a spawned
  known window (à la `FAB_REAL_ASR`); skipped otherwise.
- SpeechAnalyzer contextual strings: extend the conditional
  `FAB_REAL_ASR` suite — `say`-synthesized audio containing a rare term,
  assert the session accepts context without failing; accuracy
  assertion best-effort/tolerant.

## Out of scope (deliberately)

- Screenshot + OCR fallback for AX-poor apps (new permission; revisit
  only if AX coverage disappoints in practice).
- WhisperKit `promptTokens` biasing — prompts steer Whisper's style and
  can induce hallucination; needs its own measured experiment.
- Per-app screen-context disable (per-app overrides has the natural UI
  slot if wanted later).
- Persistent per-app vocabulary learning.
- Dictionary-based term filtering (NSSpellChecker via an injected
  protocol) — heuristics first, measure.
- Metrics schema changes — log-only observability in v1.
