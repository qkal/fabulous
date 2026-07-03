# Phase 5 — Streaming dictation (SpeechAnalyzer)

**Status:** approved design, not yet implemented
**Date:** 2026-07-03

## Goal

Cut real end-to-end latency by feeding audio to the engine *while the user is
still speaking*, so most decoding is done by the time the hotkey is released.
Injection should feel near-instant. Live partial text in the overlay is a
secondary benefit that comes along for free.

Scope is **SpeechAnalyzer only**. Its API is built for streaming (async input
stream, volatile results, finalize on demand). WhisperKit keeps the batch path
unchanged; streaming becomes another differentiator in the ongoing Whisper vs
Apple Speech A/B.

## Non-goals

- No streaming for WhisperKit (chunked re-decode is poor quality and heavy).
- No live injection into the target app while speaking; injection still
  happens once, on release.
- No change to the default engine. Whisper stays default pending the A/B.

## Architecture

### New protocol (TranscriptionEngine)

```swift
public protocol StreamingTranscriptionBackend: TranscriptionBackend {
    /// Opens a live transcription session. One session per utterance.
    func startStreamingSession() async throws -> any StreamingSession
}

public protocol StreamingSession: Sendable {
    /// Appends 16 kHz mono Float32 samples captured since the last feed.
    func feed(_ samples: [Float]) async

    /// Best transcript so far: finalized pieces + current volatile tail.
    /// Emits a fresh full string on every update (not deltas).
    var partials: AsyncStream<String> { get }

    /// Signals end of audio, waits for final decode. Fast: most work
    /// already happened during recording.
    func finish() async throws -> Transcript

    /// Abandons the session (Esc, error). Safe to call at any time.
    func cancel() async
}
```

`SpeechAnalyzerBackend` conforms. A session is an actor wrapping one
transcriber + analyzer pair (modules are single-use, per utterance — same as
today), holding the `AsyncStream<AnalyzerInput>` input open for the whole
utterance. The transcriber is configured to report volatile results in
addition to final ones. `finish()` = end input stream, `finalizeAndFinish`,
join finalized pieces — identical to the existing batch tail.

`WhisperKitBackend` does not conform. Callers detect capability with a
runtime conformance check (`backend as? StreamingTranscriptionBackend`).

### Capture side (AudioCapture)

- `TapProcessor` gains `drainNew() -> [Float]`: returns samples accumulated
  since the previous `drainNew()` call (internal cursor). The existing
  `drain()` (everything, at stop) is unchanged, so the full buffer is always
  available for batch fallback. The cursor survives device configuration
  changes because `TapProcessor` already keeps one continuous sample vector
  across re-taps.
- `AudioRecorder` exposes `pollNewSamples() -> [Float]` forwarding to the tap
  processor. Recording always accumulates the full utterance regardless of
  streaming.
- `AudioRecorder.stop()` gains a raw variant (e.g. `stop(trimming: Bool)` or
  a `stopRaw()`): in the streaming path the trimmed buffer is never used, and
  running Silero over the whole utterance at release would reintroduce the
  exact latency this phase removes. The streaming path stops untrimmed; VAD
  trimming runs lazily only when falling back to batch.

### AppController flow (FabulousApp)

- **beginRecording:** if selected engine is Apple Speech and the backend is
  a `StreamingTranscriptionBackend`, kick off `startStreamingSession()` in a
  concurrent task so it never delays `state = .recording` or the overlay.
  Samples accumulate in the tap regardless; the first `feed` after the
  session becomes ready catches up via the `drainNew` cursor. If session
  creation throws, log and continue with no session — recording proceeds
  exactly as today (no user-visible error).
- **While recording:** a feed step runs on the existing level-update loop
  (every ~5th tick, ≈250 ms): `pollNewSamples()` → `session.feed()`. A
  separate task consumes `session.partials`, hops to the main actor, updates
  the overlay. 250 ms of buffering is noise next to the seconds saved.
- **finishRecording:** stop the recorder *untrimmed*. If audio is shorter
  than `minimumUtteranceDuration`, `cancel()` the session (don't leak it)
  and bail as today. Otherwise, with a live session, `finish()` and use its
  transcript — VAD trim and batch `transcribe()` both skipped. If `finish()`
  throws, VAD-trim the full buffer and fall back to the batch path.
- **cancelRecording (Esc):** `session.cancel()`, then the existing cleanup.
- **Task hygiene:** the partials-consuming task and the feed loop are
  cancelled in both `finishRecording` and `cancelRecording` *before* the
  overlay transitions, so a late partial can never repaint a hidden pill.
  The session actor ignores `feed` calls arriving after `finish()`/`cancel()`
  has begun (the feed timer races the stop path by design).
- Everything downstream of the final transcript is unchanged: focus-change
  guard, replacements/post-processing, history, injection, safety net.

### Overlay (OverlayController)

While recording *with a live session*, the pill grows one text line showing
the tail of the current partial (tail-truncated to fit; volatile portion in a
secondary color). Without a session (Whisper, or session failed) the overlay
looks exactly like today. The comet-arc spinner still covers the finalize
gap, which is now much shorter.

Partials are raw engine output; the injected text may differ slightly after
post-processing. That is expected and normal for dictation UIs.

## Decisions folded in

- **VAD is skipped in the streaming path.** The analyzer handles silence
  itself. Silero/EnergyVAD still trim the batch-fallback and Whisper paths.
- **Post-processing runs once, on the final transcript.** Never on partials.
- **Metrics:** `DictationMetrics.transcription` in the streaming path
  measures release→final (the finalize wait) — the number the user feels.
  `stopAndTrim` shrinks to just engine stop + drain (no VAD) there; that is
  accurate, not a lie, since no trimming ran. New boolean field
  `DictationMetrics.streamed` persisted via a `v3-metrics-streamed`
  GRDB migration (default false for old rows), so per-engine p50/p90
  comparisons in the A/B stay honest. The menu keeps showing per-engine
  stats unchanged; `streamed` exists for log/DB analysis.

## Error handling

| Failure | Behavior |
|---|---|
| Session creation throws at record start | Log; record as batch (silent degrade) |
| `feed`/analyzer error mid-utterance | Session marks itself dead; `finish()` throws; batch fallback |
| `finish()` throws | Batch transcribe of the full VAD-trimmed buffer |
| Esc during recording | `cancel()` the session; existing cancel flow |
| Utterance below `minimumUtteranceDuration` | `cancel()` the session; bail silently as today |
| `feed` after finish/cancel began | Session ignores it (feed timer races the stop path) |
| Device config change (AirPods) mid-recording | `TapProcessor` keeps sample continuity; `drainNew` cursor unaffected |
| Empty audio | Empty transcript, same as today |

Invariant preserved: **transcripts are never silently lost.** The full buffer
is always captured, so every streaming failure degrades to the exact batch
path that exists today, including `safetyNet` on injection failure.

## Testing

- **PipelineTests (always run):** fake `StreamingTranscriptionBackend` —
  chunks arrive via `feed` in order; `finish()` text is used and batch
  transcribe is *not* called; session-creation failure and `finish()` failure
  both fall back to batch; Esc cancels the session; short utterance cancels
  the session; `feed` after finish is ignored.
- **TapProcessor unit tests:** `drainNew` cursor — incremental drains sum to
  `drain()`, cursor survives converter rebuild (config change).
- **HistoryStore tests:** `v3` migration adds `streamed`; old rows read back
  as `streamed == false`.
- **Real-engine (conditional, `FAB_REAL_ASR=1`):** stream `say`-synthesized
  audio in 250 ms chunks; assert at least one partial arrives before
  `finish()`; final text matches the batch result for the same audio
  (normalized comparison).

## Out of scope / future

- Streaming Parakeet/FluidAudio backend (protocol seam now exists).
- Live injection while speaking.
- Partial-text UI beyond the single tail line in the pill.
