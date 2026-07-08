# Parakeet Hybrid Mode + Short-Utterance Padding (PR B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Parakeet final text always comes from the accurate TDT v3 batch decode while EOU 120M keeps streaming overlay partials; sub-0.30 s utterances get zero-padded past FluidAudio's sample-count cliff instead of dropped.

**Architecture:** `StreamingDictation.finalTranscript` (the existing pure fallback seam) gains a `FinalTranscriptPolicy`: `.streamPreferred` (current behavior, Apple Speech) vs `.batchFinal` (hybrid, Parakeet) — batch runs first, streaming session is cancelled on success and `finish()`ed only as rescue. `AppController` picks the policy from the engine kind and skips the VAD re-trim on the hybrid primary path. `ParakeetBackend` pads short buffers to the 4800-sample floor, validated by a `FAB_REAL_ASR` empirical test that decides the min-duration guard's fate.

**Tech Stack:** Swift 6 strict concurrency, SwiftPM, Swift Testing, FluidAudio v0.15.4.

**Spec:** `docs/superpowers/specs/2026-07-08-cleanup-gate-parakeet-hybrid-design.md` (Track 2)

## Global Constraints

- **PREREQUISITE SATISFIED 2026-07-08:** PR #8 (2290862) AND the public-readiness hardening (PR #9, 469a189) are both merged to main. `AppController.finishRecording` line anchors in this plan predate BOTH merges — always re-locate with grep, and preserve the hardening additions (safety-net gating, history write chain, secure-input handling) when threading the policy through.
- Build must stay warning-free: `swift build --arch arm64` (arm64 only, never x86_64).
- Run tests with `swift test` from repo root (never cd into `.build/checkouts`).
- Swift Testing (`@Test`, `#expect`), not XCTest.
- Invariant: a transcript is never silently lost — the rescue matrix must be exhaustive in both policy directions.
- In files importing both FluidAudio and FabCore: qualify `FabCore.Language`, `FabCore.AudioBuffer`; FluidAudio's `Language` comes via the existing `import enum FluidAudio.Language`.
- Streaming stop stays `trimming: false` — do not "fix" it back.
- Branch: `parakeet-hybrid` from post-PR-#8 `main`.

---

### Task 1: `FinalTranscriptPolicy` + `.batchFinal` in `StreamingDictation`

**Files:**
- Modify: `Sources/TranscriptionEngine/StreamingTranscription.swift:52-72` (`StreamingDictation`)
- Test: `Tests/PipelineTests/StreamingPipelineTests.swift`

**Interfaces:**
- Consumes: existing `StreamingSession` protocol, `Transcript`.
- Produces (Task 2 relies on these exact names):

```swift
public enum FinalTranscriptPolicy: Sendable {
    case streamPreferred
    case batchFinal
}
// New signature (default preserves every existing call site):
StreamingDictation.finalTranscript(
    session: (any StreamingSession)?,
    policy: FinalTranscriptPolicy = .streamPreferred,
    fallback: @Sendable () async throws -> Transcript
) async throws -> (transcript: Transcript, streamed: Bool)
```

- [ ] **Step 1: Write the failing matrix tests**

Add to `StreamingPipelineTests` (reuse its `FakeSession` — it already records `finished`/`cancelled` flags — and `SessionDied`/`batchTranscript()` helpers):

```swift
    // MARK: .batchFinal (hybrid) matrix

    @Test func batchFinalUsesBatchAndCancelsSession() async throws {
        let session = FakeSession(
            finishResult: .success(Transcript(text: "streamed text", audioDuration: 1)))
        let (transcript, streamed) = try await StreamingDictation.finalTranscript(
            session: session, policy: .batchFinal,
            fallback: { Self.batchTranscript() })
        #expect(transcript.text == "batch text")
        #expect(!streamed)
        // EOU finalize wait is never paid for text we discard.
        #expect(await session.cancelled)
        #expect(await !session.finished)
    }

    @Test func batchFinalRescuesFromStreamWhenBatchThrows() async throws {
        struct BatchDied: Error {}
        let session = FakeSession(
            finishResult: .success(Transcript(text: "streamed text", audioDuration: 1)))
        let (transcript, streamed) = try await StreamingDictation.finalTranscript(
            session: session, policy: .batchFinal,
            fallback: { throw BatchDied() })
        #expect(transcript.text == "streamed text")
        #expect(streamed)
        #expect(await session.finished)
    }

    @Test func batchFinalRescuesFromStreamWhenBatchIsEmpty() async throws {
        let session = FakeSession(
            finishResult: .success(Transcript(text: "streamed text", audioDuration: 1)))
        let (transcript, streamed) = try await StreamingDictation.finalTranscript(
            session: session, policy: .batchFinal,
            fallback: { Transcript(text: "", audioDuration: 0) })
        #expect(transcript.text == "streamed text")
        #expect(streamed)
    }

    @Test func batchFinalEmptyEverywhereReturnsEmptyBatch() async throws {
        let session = FakeSession(
            finishResult: .success(Transcript(text: "", audioDuration: 0)))
        let (transcript, streamed) = try await StreamingDictation.finalTranscript(
            session: session, policy: .batchFinal,
            fallback: { Transcript(text: "", audioDuration: 0) })
        #expect(transcript.text.isEmpty)
        #expect(!streamed)
    }

    @Test func batchFinalThrowsBatchErrorWhenRescueAlsoDies() async throws {
        struct BatchDied: Error {}
        let session = FakeSession(finishResult: .failure(SessionDied()))
        await #expect(throws: BatchDied.self) {
            _ = try await StreamingDictation.finalTranscript(
                session: session, policy: .batchFinal,
                fallback: { throw BatchDied() })
        }
        // Session must still be ended exactly once (cancel after failed finish).
        #expect(await session.cancelled)
    }

    @Test func batchFinalWithoutSessionJustRunsBatch() async throws {
        let (transcript, streamed) = try await StreamingDictation.finalTranscript(
            session: nil, policy: .batchFinal,
            fallback: { Self.batchTranscript() })
        #expect(transcript.text == "batch text")
        #expect(!streamed)
    }
```

Note: if `FakeSession.finish()` asserts it is never called after `cancel()`, keep that behavior — the implementation must never do both except cancel-after-failed-finish.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter StreamingPipelineTests`
Expected: FAIL — no `policy:` parameter.

- [ ] **Step 3: Implement**

Replace `StreamingDictation` in `StreamingTranscription.swift` (keep the existing doc comment for the `.streamPreferred` path, extend for hybrid):

```swift
/// Which output wins when a streaming session and the batch decoder are both
/// available for one utterance.
public enum FinalTranscriptPolicy: Sendable {
    /// Streamed text wins when the session survived and produced text
    /// (Apple Speech: its streamed final IS its best output).
    case streamPreferred
    /// Batch decode is the final text; the streamed result is only a rescue
    /// when batch throws or returns empty (Parakeet hybrid: EOU 120M
    /// partials for the overlay, TDT v3 accuracy for the inserted text).
    case batchFinal
}

/// The fallback invariant in one place: whichever policy runs, a transcript
/// is never silently lost — each side rescues the other.
public enum StreamingDictation {
    public static func finalTranscript(
        session: (any StreamingSession)?,
        policy: FinalTranscriptPolicy = .streamPreferred,
        fallback: @Sendable () async throws -> Transcript
    ) async throws -> (transcript: Transcript, streamed: Bool) {
        switch policy {
        case .streamPreferred:
            if let session {
                do {
                    let transcript = try await session.finish()
                    if !transcript.text.isEmpty {
                        return (transcript, true)
                    }
                    // Empty streamed text: fall through to batch (no cancel —
                    // finish succeeded). The caller still has the full buffer.
                } catch {
                    await session.cancel()
                    // Fall through to batch; the caller still has the full buffer.
                }
            }
            return (try await fallback(), false)

        case .batchFinal:
            do {
                let transcript = try await fallback()
                if !transcript.text.isEmpty || session == nil {
                    // Batch won: never pay the EOU finalize wait for text we
                    // discard — cancel, don't finish.
                    if let session { await session.cancel() }
                    return (transcript, false)
                }
                // Batch empty but a session exists: try the streamed rescue.
                if let rescued = await Self.rescue(session!) {
                    return (rescued, true)
                }
                return (transcript, false)
            } catch {
                // Batch died: the streamed text is the rescue.
                if let session, let rescued = await Self.rescue(session) {
                    return (rescued, true)
                }
                throw error
            }
        }
    }

    /// Finish the session and return its text if usable; ends the session
    /// exactly once either way (cancel after a failed finish).
    private static func rescue(_ session: any StreamingSession) async -> Transcript? {
        do {
            let transcript = try await session.finish()
            return transcript.text.isEmpty ? nil : transcript
        } catch {
            await session.cancel()
            return nil
        }
    }
}
```

Note the subtle case: batch empty + session finish returns empty → session was finished (not cancelled), which is fine — finish is a valid end-of-life.

- [ ] **Step 4: Run the full streaming suite**

Run: `swift test --filter StreamingPipelineTests`
Expected: PASS — all new matrix tests AND all pre-existing `.streamPreferred` tests (default parameter keeps old call sites compiling unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/TranscriptionEngine/StreamingTranscription.swift Tests/PipelineTests/StreamingPipelineTests.swift
git commit -m "feat: FinalTranscriptPolicy — batchFinal hybrid with streamed rescue"
```

---

### Task 2: `AppController` selects the policy; hybrid skips the VAD re-trim

**Files:**
- Modify: `Sources/FabulousApp/AppController.swift:615-640` (`finishRecording`, the `finalTranscript` call — line numbers are pre-PR-#8; re-locate with `grep -n "finalTranscript" Sources/FabulousApp/AppController.swift`)
- Test: `Tests/PipelineTests/StreamingPipelineTests.swift` (policy-selection unit)

**Interfaces:**
- Consumes: `FinalTranscriptPolicy` (Task 1), `TranscriptionEngineKind` (FabCore, cases include `.parakeet` — verify with `grep -n "case " Sources/FabCore/ModelDescriptor.swift`).
- Produces: `FinalTranscriptPolicy.for(engine:)` static, used only by `AppController`.

- [ ] **Step 1: Write the failing policy-selection test**

In `StreamingPipelineTests.swift`:

```swift
    @Test func policyPerEngine() {
        #expect(FinalTranscriptPolicy.for(engine: .parakeet) == .batchFinal)
        #expect(FinalTranscriptPolicy.for(engine: .appleSpeech) == .streamPreferred)
        #expect(FinalTranscriptPolicy.for(engine: .whisper) == .streamPreferred)
    }
```

(`TranscriptionEngineKind` cases verified: `whisper`, `appleSpeech`, `parakeet` — `Sources/FabCore/ModelDescriptor.swift:64`.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter StreamingPipelineTests`
Expected: FAIL — `for(engine:)` not defined.

- [ ] **Step 3: Implement selection + wire `AppController`**

In `StreamingTranscription.swift`, extend the enum (needs `import FabCore`, already present):

```swift
extension FinalTranscriptPolicy {
    /// Whisper never opens a session, so its value is inert — listed for
    /// exhaustiveness.
    public static func `for`(engine: TranscriptionEngineKind) -> FinalTranscriptPolicy {
        switch engine {
        case .parakeet: .batchFinal
        default: .streamPreferred
        }
    }
}
```

In `AppController.finishRecording`, pass the policy and make the fallback closure trim-aware. The current closure VAD-trims a raw buffer before batch — correct for the rare `.streamPreferred` fallback, but hybrid runs batch every dictation and must NOT re-add the stop-trim latency the streaming path exists to remove (v3 tolerates silence at ~190× real time):

```swift
            let policy = FinalTranscriptPolicy.for(engine: settings.transcriptionEngine)
            let (transcript, streamed) = try await StreamingDictation.finalTranscript(
                session: session,
                policy: policy,
                fallback: { [recorder] in
                    guard !capturedAudio.isEmpty else {
                        return Transcript(text: "", audioDuration: 0)
                    }
                    // Raw buffer + streamPreferred: the rare batch fallback
                    // pays one lazy VAD pass (pre-hybrid behavior). Raw
                    // buffer + batchFinal: decode untrimmed — this runs
                    // every dictation and the trim would re-add exactly the
                    // stop-latency streaming removed; v3 shrugs at silence.
                    if audioIsRaw && policy == .streamPreferred {
                        var trimmed = await recorder.trimSilence(capturedAudio)
                        defer { trimmed.zero() }
                        guard !trimmed.isEmpty else {
                            return Transcript(text: "", audioDuration: 0)
                        }
                        return try await batchBackend.transcribe(trimmed, language: nil)
                    }
                    return try await batchBackend.transcribe(capturedAudio, language: nil)
                }
            )
```

(Adapt to the closure's post-PR-#8 shape — PR #8 touched `finishRecording`; the trim-if-raw structure is what to preserve for `.streamPreferred`.)

- [ ] **Step 4: Verify**

Run: `swift build --arch arm64 && swift test`
Expected: zero warnings, all green. `AppController` has no test target (known gap) — the policy table and rescue matrix are the tested logic; the wiring is one parameter + one condition.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranscriptionEngine/StreamingTranscription.swift Sources/FabulousApp/AppController.swift Tests/PipelineTests/StreamingPipelineTests.swift
git commit -m "feat: Parakeet dictations finalize via batch decode (hybrid policy)"
```

---

### Task 3: Zero-pad short buffers past the 4800-sample cliff

**Files:**
- Modify: `Sources/TranscriptionEngine/ParakeetBackend.swift` (`batchMinimumDuration` block + `transcribe` guard — post-PR-#8 shape)
- Test: `Tests/TranscriptionEngineTests/ParakeetMinDurationTests.swift`

**Interfaces:**
- Consumes: post-PR-#8 `ParakeetBackend.isBelowBatchMinimum(_:)`, `batchMinimumDuration` (0.30), `FabCore.AudioBuffer(samples:sampleRate:)`.
- Produces: `ParakeetBackend.paddedToBatchFloor(_ audio: FabCore.AudioBuffer) -> FabCore.AudioBuffer` (static, pure), `batchFloorSamples = 4_800`. Task 4's empirical test exercises the padded path end-to-end.

- [ ] **Step 1: Write the failing tests**

Add to `ParakeetMinDurationTests.swift`:

```swift
    @Test func shortBufferIsPaddedToExactFloor() {
        // 0.2 s at 16 kHz = 3200 samples — below FluidAudio's measured
        // 4800-sample invalidAudioData cliff.
        let short = FabCore.AudioBuffer(
            samples: [Float](repeating: 0.1, count: 3_200), sampleRate: 16_000)
        let padded = ParakeetBackend.paddedToBatchFloor(short)
        #expect(padded.samples.count == 4_800)
        // Original audio is a prefix; the tail is digital silence.
        #expect(Array(padded.samples.prefix(3_200)) == short.samples)
        #expect(padded.samples.suffix(1_600).allSatisfy { $0 == 0 })
        #expect(padded.sampleRate == 16_000)
    }

    @Test func longBufferIsUntouched() {
        let ok = FabCore.AudioBuffer(
            samples: [Float](repeating: 0.1, count: 8_000), sampleRate: 16_000)
        let padded = ParakeetBackend.paddedToBatchFloor(ok)
        #expect(padded.samples.count == 8_000)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ParakeetMinDurationTests`
Expected: FAIL — `paddedToBatchFloor` not defined.

- [ ] **Step 3: Implement**

In `ParakeetBackend.swift`, next to `batchMinimumDuration`:

```swift
    /// FluidAudio's measured invalidAudioData cliff: exactly 4800 samples
    /// (0.300 s @ 16 kHz) — see the batchMinimumDuration NOTE above.
    static let batchFloorSamples = 4_800

    /// Short utterances get trailing digital silence up to the decoder
    /// floor instead of being dropped — the cliff becomes unreachable.
    /// Padding covers both the hybrid primary decode and the rescue path,
    /// since both land in transcribe().
    static func paddedToBatchFloor(_ audio: FabCore.AudioBuffer) -> FabCore.AudioBuffer {
        guard audio.samples.count < batchFloorSamples else { return audio }
        var samples = audio.samples
        samples.append(
            contentsOf: [Float](repeating: 0, count: batchFloorSamples - samples.count))
        return FabCore.AudioBuffer(samples: samples, sampleRate: audio.sampleRate)
    }
```

In `transcribe`, replace the PR #8 early-return guard usage so padding happens instead of dropping (keep `isBelowBatchMinimum` itself — Task 4 decides its threshold):

```swift
        guard !audio.isEmpty else {
            return Transcript(text: "", audioDuration: 0)
        }
        guard !Self.isBelowBatchMinimum(audio) else {
            return Transcript(text: "", audioDuration: audio.duration)
        }
        let decodable = Self.paddedToBatchFloor(audio)
```

…and decode `decodable.samples` in the `manager.transcribe` call, keeping `audioDuration: audio.duration` (the real, unpadded duration) in the returned `Transcript`.

Check `FabCore.AudioBuffer`'s memberwise init signature first (`grep -n "public init" Sources/FabCore/AudioBuffer.swift`) — adapt if it has extra parameters.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter ParakeetMinDurationTests && swift build --arch arm64`
Expected: PASS, zero warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranscriptionEngine/ParakeetBackend.swift Tests/TranscriptionEngineTests/ParakeetMinDurationTests.swift
git commit -m "feat: pad short Parakeet buffers to the 4800-sample decoder floor"
```

---

### Task 4: Empirical blip test decides the min-duration guard threshold

**Files:**
- Modify: `Tests/TranscriptionEngineTests/ParakeetBackendTests.swift` — it already has the `say`-synthesis helper (~line 90: `/usr/bin/say` with `--data-format=LEF32@16000` into a 16 kHz mono Float32 buffer) and the `FAB_REAL_ASR` gating idiom; add the blip test there rather than a new file.
- Modify: `Sources/TranscriptionEngine/ParakeetBackend.swift` (`batchMinimumDuration`) — only if the blip decodes.

**Interfaces:**
- Consumes: `ParakeetBackend` with padding (Task 3), installed Parakeet models on the dev machine, `say` CLI.
- Produces: the empirical verdict the spec requires; possibly `batchMinimumDuration = 0.05`.

- [ ] **Step 1: Write the real-ASR blip test**

Add to `ParakeetBackendTests.swift`, using its existing synthesis helper and env-gate (match the suite's exact gating/helper names — read the file first):

```swift
    @Test func paddedBlipDecodes() async throws {
        // Real-engine validation of the zero-padding hypothesis: does a
        // padded sub-0.3 s blip decode to real text, or garbage?
        // Synthesize "yes", then slice to the voiced prefix so the buffer
        // sits below the 4800-sample cliff.
        var audio = try synthesizedAudio(text: "yes")  // suite's existing helper name
        if audio.samples.count >= 4_800 {
            audio = FabCore.AudioBuffer(
                samples: Array(audio.samples.prefix(4_500)), sampleRate: 16_000)
        }
        try #require(audio.samples.count < 4_800, "blip must sit below the cliff to test padding")
        let backend = ParakeetBackend()
        try await backend.load(model: .parakeetV3)
        let transcript = try await backend.transcribe(audio, language: nil)
        // Hypothesis check: non-empty and contains the word.
        #expect(transcript.text.lowercased().contains("yes"))
    }
```

If trimming `say` output below 0.30 s proves fiddly, synthesize then slice the sample array to the voiced prefix — the goal is a real-speech buffer under 4800 samples.

- [ ] **Step 2: Run it (requires models installed)**

Run: `FAB_REAL_ASR=1 swift test --filter ParakeetShortUtteranceRealTests`

- [ ] **Step 3: Act on the verdict (spec's empirical gate)**

**If it decodes correctly:** lower the guard to a true-noise floor in `ParakeetBackend.swift` —

```swift
    /// Padding (paddedToBatchFloor) makes the 4800-sample cliff unreachable,
    /// so this is no longer the decoder floor — just a noise floor below any
    /// real word (empirical: padded blips decode fine, 2026-07-XX).
    static let batchMinimumDuration: TimeInterval = 0.05
```

Update `ParakeetMinDurationTests.subThresholdBufferIsBelowMinimum` to use a sub-0.05 s buffer (e.g. 400 samples) and re-run `swift test --filter ParakeetMinDurationTests`.

**If it returns garbage/empty:** keep `batchMinimumDuration = 0.30`, mark the blip test's `#expect` as the documented negative result (flip it to record the actual behavior, with a comment), and note the limitation in the PR body — blips remain Whisper's advantage; the safety net catches them visibly. This outcome does not block the PR.

- [ ] **Step 4: Full sweep**

```bash
swift build --arch arm64 && swift test
```
Expected: zero warnings, all green (real-ASR suites auto-skip without the env var).

- [ ] **Step 5: Commit**

```bash
git add Sources/TranscriptionEngine/ParakeetBackend.swift Tests/TranscriptionEngineTests/
git commit -m "test: real-ASR padded-blip verdict; set min-duration guard accordingly"
```

---

### Task 5: Full verification + PR

**Files:** none new.

- [ ] **Step 1: Full build + test + live-fire**

```bash
swift build --arch arm64 && swift test
FAB_REAL_ASR=1 swift test --filter TranscriptionEngineTests
scripts/build.sh && open build/fabulous.app
```

Manual smoke (Parakeet engine selected): dictate a long utterance — overlay shows partials, inserted text is the v3 decode; dictate a short blip — padded decode or visible safety net per Task 4's verdict; check menu — per-engine stats line updates, log line shows no `streamed` flag on hybrid dictations (rescue path only).

- [ ] **Step 2: Push + PR**

```bash
git push -u origin parakeet-hybrid
gh pr create --title "Parakeet hybrid: v3 batch finals, streamed partials, padded blips" --body "$(cat <<'EOF'
Parakeet dictations now finalize via TDT v3 batch decode (accuracy) while
EOU 120M keeps feeding overlay partials (live feel). Batch runs first and
the session is cancelled on success; streamed text is the rescue when batch
fails. Hybrid primary path decodes the untrimmed buffer (no VAD re-trim
latency). Sub-0.30 s utterances are zero-padded past FluidAudio's
4800-sample cliff, with a FAB_REAL_ASR empirical test recording the verdict.

Resolves the stay-120M / hybrid / batch-only dogfood decision as hybrid.
Spec: docs/superpowers/specs/2026-07-08-cleanup-gate-parakeet-hybrid-design.md (Track 2)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

**After merge:** Kal dogfoods Parakeet as daily driver (menu p50/p90, `rejected` cleanup rate, subjective accuracy). The "Recommended" badge in the engine picker is a separate tiny commit triggered by Kal's decision — deliberately NOT in this plan.
