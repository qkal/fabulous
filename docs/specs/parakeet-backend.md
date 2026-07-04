# Parakeet backend (FluidAudio)

**Date:** 2026-07-04 (amended same day after codebase + FluidAudio doc verification)
**Status:** implemented 2026-07-04

## Goal

A third transcription engine: NVIDIA Parakeet via the FluidAudio Swift
package, on-device CoreML. The bet: Whisper-class accuracy at
Apple-Speech-class latency. Whisper stays the default; Parakeet ships
behind the existing Settings → General engine picker as an experimental
option, and the decision to promote it is made from dogfood data in the
metrics menu (per-engine p50/p90), same playbook as phase 4.

Streaming is in scope from day one. FluidAudio's streaming API
(`StreamingEouAsrManager`) runs a smaller Parakeet EOU 120M model — not
TDT 0.6b v3 — so streamed final text comes from the 120M model (decided
with that trade-off known). The batch path (v3) remains the fallback, and
dogfood accuracy decides whether streamed finals stay 120M, move to a
hybrid (120M partials, v3 final decode), or streaming gets dropped for
batch-only. The seam makes those swaps cheap.

## Models

Two FluidAudio model sets, presented as ONE "Parakeet" row in the Models
tab:

- **parakeet-tdt-0.6b-v3** (multilingual, ~25 European languages) — batch
  decode and streaming fallback.
- **parakeet EOU 120M** — `StreamingEouAsrManager`'s streaming model.

v2 (English-only) is out of scope.

## Approach (decided)

FluidAudio is used for model loading and decode. Verified against its
docs: `AsrModels.load(from: repoDirectory, version: .v3)` accepts a
caller-supplied directory, so installed models can live in our tree.

**There is no generic hub client in this codebase** — Whisper downloads go
through `WhisperKit.download(variant:downloadBase:)`, which is pinned to
the argmaxinc repo. So Parakeet downloads use FluidAudio's own download
API, redirected at our models directory if its API allows (verify exact
parameters — implementation task #1); if it only supports its own cache
location, download there and either symlink/move into our tree or teach
`ModelLayout` that location. Whichever lands, `ModelLayout` (parametrized
by repo) remains the single source of truth for "is it installed/complete",
and the Models tab drives progress/size/delete through `ModelManager` as
it does for Whisper.

Rejected alternatives:
- **FluidAudio full-stack** (invisible cache, no Models tab row): rejected
  for UX consistency.
- **Raw CoreML, no dependency** (own TDT decoder + tokenizer): weeks of
  work, not worth it for an experimental engine.
- **Writing our own generic HF downloader**: only if FluidAudio's download
  API can't be pointed anywhere sane; decided at the risk gate, not now.

## Architecture

- New SPM dependency: `FluidAudio` (FluidInference). Imported **only** by
  `TranscriptionEngine` — same rule as WhisperKit. CLAUDE.md dependency
  note updated to name both.
- New `ParakeetBackend` actor in `TranscriptionEngine` implementing
  `TranscriptionBackend` and `StreamingTranscriptionBackend`. FluidAudio's
  non-Sendable manager types are confined inside the actor;
  `@retroactive @unchecked Sendable` only if the compiler requires it —
  mirror of `WhisperKitBackend`.
- **Name collision gotcha:** FluidAudio declares its own `Language` (and
  possibly other names colliding with FabCore). Qualify explicitly in any
  file importing both — same class of problem as WhisperKit's `EnergyVAD`
  and CoreAudio's `AudioBuffer`. Add to CLAUDE.md gotchas during
  implementation.
- FabCore additions:
  - `TranscriptionEngineKind.parakeet`, display name "Parakeet
    (experimental)".
  - `ModelDescriptor.parakeetV3` — with real on-disk size in MB (both
    model sets combined), filled at implementation.

## Model management

- `ModelCatalog` splits: `whisperVariants` (today's `all`) keeps driving
  the Whisper variant picker and `selectedModelID`, whisper-only. Parakeet
  is a separate catalog entry shown in the Models tab with the same
  download-progress/delete affordances.
- **Descriptor lookup must stay unified:** the menu's latency-stats line
  resolves engine names via `ModelCatalog.descriptor(withID:)` plus an
  `appleSpeech` special case (`AppController.statsSummary`). The split
  catalog needs one lookup that covers whisper variants + parakeet +
  appleSpeech, or the menu shows a raw ID.
- `ModelLayout` parametrized by hub repo (org/name); Parakeet installs
  under the same hub-shaped tree
  (`models/models/FluidInference/<repo>/`), `requiredComponents` per repo
  enumerated during implementation. Covers both model sets.
- The single Models-tab "Parakeet" row downloads both sets; size on disk
  is their sum; delete removes both.

## Streaming and data flow

- `ParakeetBackend.startStreamingSession()` returns a
  `ParakeetStreamingSession` wrapping `StreamingEouAsrManager`:
  - `feed(_:)` converts 16 kHz mono `[Float]` chunks to `AVAudioPCMBuffer`
    (the FluidAudio API takes buffers) and forwards via
    `process(audioBuffer:)`.
  - Partial callback → `partials` stream (fresh full string per update,
    single consumer — same contract as the Apple Speech session).
  - `finish()` finalizes the manager and returns a `Transcript` built from
    its session text; `cancel()` resets/abandons.
  - EOU auto-detection is irrelevant to us — the user's hotkey release
    ends the utterance; we call `finish()` ourselves. Configure the
    manager's debounce so it never end-points mid-dictation, and ignore
    the EOU callback.
- Existing invariants inherited untouched: the streaming path stops the
  recorder with `trimming: false`; `StreamingDictation.finalTranscript`
  falls back to a batch decode over the full untrimmed buffer on any
  failure or empty streamed result. A transcript is never silently lost.
- Batch `transcribe` uses FluidAudio's batch `AsrManager` (v3) over the
  whole buffer — the fallback, and the path when a streaming session can't
  open.
- `AppController` is unchanged — the runtime
  `StreamingTranscriptionBackend` capability check already routes
  streaming-capable engines.

## Settings, metrics, failure UX

- Settings → General: the Transcription engine section is currently
  wrapped in `#available(macOS 26.0, *)`. Restructure so the section is
  always visible (Parakeet needs only the package's macOS 14 floor); the
  Apple Speech option alone stays 26-gated. Footnote text updated to cover
  Parakeet.
- Selecting Parakeet when its models aren't installed triggers download
  with progress, exactly like Whisper's first-run auto-download
  (`downloadModel(drivesAppState:)`) — no disabled picker rows.
- Engine-load failure reverts `settings.transcriptionEngine` to `.whisper`
  AND explicitly reloads Whisper — same path Apple Speech uses
  (`onEngineChanged` no-ops outside `.idle`/`.failed`, so the revert
  cannot rely on it).
- `DictationMetrics`/history record `engineID` for Parakeet dictations;
  per-engine p50/p90 menu stats work once the descriptor lookup above is
  unified.
- Keep-warm applies to the **active engine only**, matching the existing
  pattern: loading Parakeet unloads Whisper (and releases the Apple Speech
  locale hold); switching away unloads Parakeet. Both Parakeet model sets
  (v3 + 120M) stay resident while Parakeet is active. No idle unload.
- Language: there is no app-level language setting; batch decode passes
  `language: nil` (v3 auto-detects; its optional hint parameter is
  available if a setting ever appears). LLM cleanup, replacements, and
  injection sit downstream of `Transcript` and are untouched.

## Error handling

- Load errors (missing components, CoreML failure) → revert-to-Whisper
  path plus a status message naming the failure (`flashFailure`, as Apple
  Speech does).
- Streaming mid-utterance errors → batch fallback per the seam; the safety
  net (clipboard + overlay notice) is unchanged downstream.
- Download errors → map FluidAudio download failures onto the existing
  offline-detection UX (`ModelManager.isOffline` on `URLError`s) so the
  Models tab messaging stays consistent.

## Testing

- Unit tests: `ModelLayout` parametrized-repo paths and
  `requiredComponents`; catalog split (variant picker excludes Parakeet;
  unified descriptor lookup finds all engines);
  `TranscriptionEngineKind` round-trip; `[Float]` → `AVAudioPCMBuffer`
  conversion.
- `Tests/PipelineTests` already exercises the capture → decision seam with
  a fake backend; add a Parakeet-shaped fake only if a coverage gap shows
  up.
- Conditional real-engine tests: `FAB_REAL_ASR=1 swift test --filter
  ParakeetBackendTests` decodes `say`-synthesized audio with the real
  models (batch + streaming session); auto-skips unless the Parakeet
  models are installed. Mirrors `SpeechAnalyzerBackendTests`.
- Acceptance: dogfood A/B via the metrics menu — p50/p90 vs Whisper and
  Apple Speech, plus a judgment call on 120M streamed-final accuracy
  (drives the stay-120M / hybrid / batch-only decision).

## Implementation risk gates (plan task #1)

1. FluidAudio download API: can it target our models directory? Exact
   repo names + file lists for both model sets (fills `requiredComponents`
   and descriptor size).
2. `StreamingEouAsrManager.loadModels()`: does it accept a custom
   directory like `AsrModels.load(from:)`? If not, decide symlink/move vs
   taught location.
3. Confirm the streaming manager's debounce can be set high enough to
   never auto-endpoint during dictation pauses.

## As-built notes

Implemented 2026-07-04; verified against real Task 1 findings and actual
FluidAudio v0.15.4 checkout. Key overrides from provisional spec assumptions:

- **Download API**: FluidAudio's `AsrModels.download(to:)` and
  `DownloadUtils.downloadRepo()` both accept custom directories and work
  with our models tree. No taught-location fallback needed; `ParakeetInstaller`
  routes both repos directly.
- **Folder name derivation**: FluidAudio's load/download methods internally
  discard the last path component of the directory passed and re-derive it
  from `Repo.folderName`. `ParakeetLayout.repoRoot` accounts for this: leaf
  names are `parakeet-tdt-0.6b-v3` (v3, fluidaudio's own) and
  `parakeet-eou-streaming/160ms` (EOU 160ms chunk variant), NOT the HF repo IDs.
- **Streaming loader flexibility**: `StreamingEouAsrManager.loadModels(from:)`
  loads flat files directly from a supplied directory (no folderName re-derivation,
  unlike v3 batch), matching `ParakeetLayout.repoRoot(eouFolderName, downloadBase:)`.
- **No @retroactive @unchecked Sendable needed**: both `AsrManager` and
  `StreamingEouAsrManager` are Swift `actor`s, Sendable by the language
  (unlike WhisperKit's plain `class`). Task 1 concern resolved; no workaround
  added to Task 5/7.
- **FluidAudio.Language bridging**: unqualified `Language` from `import enum
  FluidAudio.Language` (scoped import); `FabCore.Language` qualified. The
  `FluidAudio` namespace-shim struct shadows `FluidAudio.Language(...)` syntax;
  workaround is the scoped enum import, documented in CLAUDE.md.
- **Streaming decoder state**: `AsrManager.transcribe` requires an externalized
  `decoderState: inout TdtDecoderState` (no zero-argument overload). Fresh
  `TdtDecoderState()` per batch call is correct for stateless use; streaming
  session manages its own state internally.
- **EOU debounce**: configurable as a plain `Int`, default 1280 ms, no ceiling.
  Set to `600_000` (10 minutes) to never auto-endpoint mid-dictation; hotkey
  release ends utterances, not silence detection. EOU callback is unregistered.
- **Model size on disk**: ~674 MB combined (460.7 MB v3 + 213.7 MB EOU 160ms),
  measured via HuggingFace API file sizes; not yet confirmed against a
  real downloaded install — re-measure via `ParakeetLayout.sizeOnDisk` if
  materially different and update `ModelDescriptor.parakeetV3.approximateSizeMB`.
- **Keep-warm active-engine-only**: loading Parakeet unloads Whisper and
  Apple Speech; both model sets (v3 + EOU) stay resident. Three-engine
  unload triangle honored.

## Out of scope

- Promoting Parakeet to default (decided later from dogfood data).
- Parakeet v2 (English-only) or multiple Parakeet variants in the UI.
- A user-facing language setting.
- Any change to the streaming seam, injection, or post-processing.
