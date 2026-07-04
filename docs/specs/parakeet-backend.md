# Parakeet backend (FluidAudio)

**Date:** 2026-07-04
**Status:** approved design, not yet implemented

## Goal

A third transcription engine: NVIDIA Parakeet TDT 0.6b v3 (multilingual)
running on-device via the FluidAudio Swift package. The bet: Whisper-class
accuracy at Apple-Speech-class latency. Whisper stays the default; Parakeet
ships behind the existing Settings → General engine picker as an
experimental option, and the decision to promote it is made from dogfood
data in the metrics menu (per-engine p50/p90), same playbook as phase 4.

Streaming is in scope from day one — Parakeet plugs into the phase-5
streaming seam so the overlay shows live partials, with the batch path as
fallback.

## Approach (decided)

FluidAudio is used for model loading and TDT decode only. Everything around
it — download, install verification, Models tab UX, offline detection —
reuses our existing hub client and `ModelLayout` infrastructure, mirroring
how WhisperKit is integrated.

Rejected alternatives:
- **FluidAudio full-stack** (its downloader, its cache dir): least code, but
  the model would be invisible to the Models tab, downloads wouldn't get our
  resume/repair or offline handling, and the first-load stall would be
  unexplained in the UI.
- **Raw CoreML, no dependency** (own TDT decoder + tokenizer): full control,
  weeks of work. Not worth it for an experimental engine.

## Architecture

- New SPM dependency: `FluidAudio` (FluidInference). Imported **only** by
  `TranscriptionEngine` — same rule as WhisperKit. CLAUDE.md dependency note
  updated to name both.
- New `ParakeetBackend` actor in `TranscriptionEngine` implementing
  `TranscriptionBackend` and `StreamingTranscriptionBackend`. FluidAudio's
  non-Sendable manager types are confined inside the actor;
  `@retroactive @unchecked Sendable` only if the compiler requires it —
  mirror of `WhisperKitBackend`.
- FabCore additions:
  - `TranscriptionEngineKind.parakeet`, display name "Parakeet
    (experimental)".
  - `ModelDescriptor.parakeetV3` — multilingual TDT 0.6b v3, with real
    on-disk size in MB (comes out of the risk-gate verification below,
    along with the component list).

## Model management

- `ModelCatalog` splits into `whisperVariants` (today's `all`; continues to
  drive the Whisper variant picker and `selectedModelID`, whisper-only) and
  a separate Parakeet entry. The Models tab lists the Parakeet row with the
  same download-progress/delete affordances, labeled as the Parakeet
  engine's model, excluded from Whisper variant selection.
- `ModelLayout` is parametrized by hub repo (org/name). Parakeet installs to
  `models/models/FluidInference/parakeet-tdt-0.6b-v3-coreml/` — the same
  hub-shaped tree as the argmaxinc Whisper variants. `requiredComponents`
  enumerated from the actual repo contents during implementation.
- Downloads go through our hub client (progress, resume/repair, offline
  detection). `ParakeetBackend.load` points FluidAudio at the installed
  directory.
- **Risk gate (implementation task #1):** verify FluidAudio can load models
  from a caller-supplied directory and enumerate the exact repo file list.
  Fallback if it can't: use FluidAudio's downloader redirected at our
  directory, wrapped in our progress UI.

## Streaming and data flow

- `ParakeetBackend.startStreamingSession()` returns a
  `ParakeetStreamingSession` wrapping FluidAudio's streaming ASR API:
  - `feed(_:)` forwards 16 kHz mono Float32 chunks.
  - `partials` emits fresh full-string updates (finalized + volatile tail) —
    same contract as the Apple Speech session.
  - `finish()` finalizes and returns a `Transcript`; `cancel()` abandons.
- Existing invariants inherited untouched: the streaming path stops the
  recorder with `trimming: false`; `StreamingDictation.finalTranscript`
  falls back to a batch decode over the full untrimmed buffer on any
  failure or empty streamed result. A transcript is never silently lost.
- Batch `transcribe` uses FluidAudio's batch manager over the whole buffer;
  it is both the fallback and the path when a streaming session can't open.
- `AppController` is unchanged — the runtime
  `StreamingTranscriptionBackend` capability check already routes
  streaming-capable engines.

## Settings, metrics, failure UX

- Settings → General engine picker gains "Parakeet (experimental)". The
  option is disabled with a hint until the Parakeet model is installed via
  the Models tab.
- Engine-load failure reverts `settings.transcriptionEngine` to `.whisper`
  AND explicitly reloads Whisper — same path Apple Speech uses
  (`onEngineChanged` no-ops outside `.idle`/`.failed`, so the revert cannot
  rely on it).
- `DictationMetrics` and history record engine `parakeet`; the per-engine
  p50/p90 menu stats work without change.
- Keep-warm: the model stays loaded for process lifetime, no idle unload
  (latency is the deal-breaker; see phase-3 reasoning).
- LLM cleanup, replacements, and injection sit downstream of `Transcript`
  and are untouched.

## Error handling

- Load errors (missing components, CoreML failure) → revert-to-Whisper path
  plus a settings hint naming the failure.
- Streaming mid-utterance errors → batch fallback per the seam; the safety
  net (clipboard + overlay notice) is unchanged downstream.
- Download errors → existing hub client resume/repair and offline
  detection.
- Language: v3 is multilingual; the app's language setting is passed
  through where FluidAudio's API accepts a language hint, otherwise
  auto-detect. Confirm during implementation and note the actual behavior
  in the settings UI if it differs from Whisper.

## Testing

- Unit tests: `ModelLayout` parametrized-repo paths and
  `requiredComponents`; catalog split (variant picker excludes Parakeet);
  `TranscriptionEngineKind` round-trip.
- `Tests/PipelineTests` already exercises the capture → decision seam with
  a fake backend; add a Parakeet-shaped fake only if a coverage gap shows
  up (e.g. streaming-session error paths not already covered).
- Conditional real-engine tests: `FAB_REAL_ASR=1 swift test --filter
  ParakeetBackendTests` decodes `say`-synthesized audio with the real
  model; auto-skips unless the Parakeet model is installed. Mirrors
  `SpeechAnalyzerBackendTests`.
- Acceptance: dogfood A/B via the metrics menu — p50/p90 vs Whisper and
  Apple Speech, accuracy judged by daily use.

## Out of scope

- Promoting Parakeet to default (decided later from dogfood data).
- Parakeet v2 (English-only) or offering multiple Parakeet variants.
- Any change to the streaming seam, injection, or post-processing.
