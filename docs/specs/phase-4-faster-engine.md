# Phase 4 — Faster engine

*Working spec, 2026-07-02. Scoped in pop-up session with kal; chosen over the
"measure first" plan — the phase-3 instrumentation data never accumulated
(metrics only went to NSLog; the unified log retained zero samples), and the
machine now runs macOS 26.5, so Apple's fast on-device SpeechAnalyzer is
testable today.*

## Problem

Latency is the stated deal-breaker, and everything after the hotkey release
is dominated by Whisper decode time. Two levers exist that don't change the
UX at all: a faster ASR engine (Apple SpeechAnalyzer, OS-managed models, ANE
optimized) and less audio to decode (a real VAD instead of energy
thresholding). Neither has been tried. Separately, the pipeline has no
end-to-end test — every phase so far has shipped on unit tests plus manual
dictation.

## Goals

1. Dictating with the Apple Speech engine works behind a settings toggle;
   WhisperKit remains the default. Identical UX: same hotkey, overlay,
   safety net, history, metrics.
2. Silero VAD (CoreML) trims silence behind the same interface as
   `EnergyVAD`, with `EnergyVAD` as automatic fallback when the VAD model
   isn't available.
3. One end-to-end pipeline test exercises resample → trim → transcribe
   (fake backend) → post-process → strategy selection, so cross-module
   regressions fail in `swift test`, not in the user's hands.
4. The A/B comparison is decidable: per-dictation metrics remain visible in
   the menu, and the engine in use is recorded with each history entry.

## Non-Goals (parked, with reasons)

- **Making Apple Speech the default** — not before dogfooded accuracy and
  latency comparison; Whisper large-v3-turbo is the known-good baseline.
- **Streaming transcription** — SpeechAnalyzer supports volatile results,
  but showing partials is a UX change; this phase is engine-swap only.
- **Parakeet/FluidAudio backend** — third engine only if SpeechAnalyzer
  disappoints.
- **Idle model unload** — keep-warm stays (phase-3 rationale unchanged).

## Requirements

### P0

| # | Requirement | Acceptance criteria |
|---|---|---|
| 1 | **`SpeechAnalyzerBackend`** (TranscriptionEngine, `@available(macOS 26,*)`) implements `TranscriptionBackend` via `SpeechAnalyzer`/`SpeechTranscriber`; assets installed through `AssetInventory` on `load`. | Toggle to Apple Speech, dictate → correct text injected; menu metrics line shows the run. |
| 2 | **Engine toggle** in Settings → General ("Transcription engine: Whisper / Apple Speech (experimental)"), only offered on macOS 26+. Switching hot-swaps the backend like a model switch; failure falls back to Whisper with a visible error. | Flip toggle → next dictation uses the other engine; relaunch persists the choice. |
| 3 | **Engine recorded per dictation** — history rows carry the engine/model that produced them (existing `modelID` column, new `apple-speech` id). | History tab shows which engine produced each transcript. |
| 4 | **E2E pipeline test** — new test target composing AudioCapture resample + VAD, a fake `TranscriptionBackend`, `ReplacementDictionary`, and `StrategySelector` over a synthetic fixture. | `swift test` runs it; breaking any stage's contract fails it. |

### P1 — stretch, in order

1. **Silero VAD** — CoreML model behind a `trimSilence`-shaped interface;
   selected automatically when its model file is installed, else
   `EnergyVAD`. Model fetched like ASR models (Application Support), never
   bundled in the repo.
2. **Real-ASR smoke test** — opt-in (env-gated) test that runs an installed
   Whisper model against a bundled spoken-word fixture.

## Success metrics

- **Leading:** menu `Last:` line for the same ~10 s utterance, Whisper vs
  Apple Speech — is ASR time materially lower? Accuracy acceptable?
- **Lagging:** after a week of A/B dogfooding, an evidence-backed decision:
  switch default / keep Whisper / try Parakeet.

## Open questions (non-blocking)

- SpeechAnalyzer accuracy on kal's dictation style vs large-v3-turbo —
  only dogfooding answers this.
- Whether SpeechAnalyzer wants its own audio format (it exposes
  `bestAvailableAudioFormat`); we feed 16 kHz mono Float32 and convert if
  the analyzer asks for something else.
- Silero model sourcing: FluidInference/silero-vad-coreml (HF) vs
  converting upstream ONNX ourselves. Resolved during implementation.
