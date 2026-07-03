# Phase 5 Streaming Dictation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Feed audio to SpeechAnalyzer while the user is still speaking so decoding overlaps recording; on hotkey release, finalize near-instantly. Live partial text shows in the overlay pill.

**Architecture:** New `StreamingTranscriptionBackend`/`StreamingSession` protocols in TranscriptionEngine; `SpeechAnalyzerBackend` implements them with a per-utterance session actor holding the analyzer input stream open. `TapProcessor` gains an incremental `drainNew()` cursor; `AppController` feeds the session every ~250 ms from the existing level-update loop. Every failure degrades to today's batch path over the fully-accumulated buffer.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, Swift Testing, Speech.framework (macOS 26 `SpeechAnalyzer`), GRDB.

**Spec:** `docs/specs/phase-5-streaming.md` — read it first.

## Global Constraints

- `swift build --arch arm64` only; never add x86_64. No .xcodeproj.
- Zero warnings under Swift 6 strict concurrency — warnings in our targets are failures.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`) — NOT XCTest.
- Dependency rule: feature modules depend only on `FabCore`; `TranscriptionEngine` must NOT import `AudioCapture` or AppKit.
- In files importing AVFoundation, qualify our buffer type as `FabCore.AudioBuffer` (CoreAudio has an `AudioBuffer` too).
- Run all commands from repo root `/Users/kal/fabulous` (never cd into `.build/checkouts`).
- Invariant: transcripts are never silently lost — every streaming failure must fall back to the batch path.
- Commit after every task.

---

### Task 1: Incremental tap drain + untrimmed stop (AudioCapture)

**Files:**
- Modify: `Sources/AudioCapture/TapProcessor.swift`
- Modify: `Sources/AudioCapture/AudioRecorder.swift`
- Test: `Tests/AudioCaptureTests/TapProcessorDrainNewTests.swift` (create)

**Interfaces:**
- Consumes: existing `TapProcessor.process/drain/level`, `AudioRecorder.stop()`.
- Produces (later tasks rely on these exact signatures):
  - `TapProcessor.drainNew() -> [Float]` — samples accumulated since previous `drainNew()`; does not disturb `drain()`.
  - `AudioRecorder.pollNewSamples() -> [Float]`
  - `AudioRecorder.stop(trimming: Bool = true) -> FabCore.AudioBuffer` — `trimming: false` returns the raw buffer, no VAD.
  - `AudioRecorder.trimSilence(_ audio: FabCore.AudioBuffer) -> FabCore.AudioBuffer` — applies the recorder's current VAD (for the lazy batch-fallback trim).

- [ ] **Step 1: Write the failing tests**

Create `Tests/AudioCaptureTests/TapProcessorDrainNewTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing

@testable import AudioCapture

@Suite struct TapProcessorDrainNewTests {
    /// 16 kHz mono buffer of constant value, `frames` long.
    private static func buffer(frames: Int, value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        let channel = buffer.floatChannelData![0]
        for i in 0..<frames { channel[i] = value }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    @Test func drainNewReturnsOnlySamplesSinceLastCall() {
        let processor = TapProcessor(targetSampleRate: 16_000)
        processor.process(Self.buffer(frames: 100, value: 0.1))
        let first = processor.drainNew()
        #expect(first.count == 100)
        #expect(first.allSatisfy { abs($0 - 0.1) < 0.001 })

        processor.process(Self.buffer(frames: 50, value: 0.2))
        let second = processor.drainNew()
        #expect(second.count == 50)
        #expect(second.allSatisfy { abs($0 - 0.2) < 0.001 })

        // Nothing new → empty, cheaply.
        #expect(processor.drainNew().isEmpty)
    }

    @Test func drainStillReturnsEverythingAfterIncrementalDrains() {
        let processor = TapProcessor(targetSampleRate: 16_000)
        processor.process(Self.buffer(frames: 100, value: 0.1))
        _ = processor.drainNew()
        processor.process(Self.buffer(frames: 50, value: 0.2))
        // drain() ignores the cursor: the full utterance, always.
        #expect(processor.drain().count == 150)
    }

    @Test func drainResetsTheCursor() {
        let processor = TapProcessor(targetSampleRate: 16_000)
        processor.process(Self.buffer(frames: 100, value: 0.1))
        _ = processor.drain()
        processor.process(Self.buffer(frames: 30, value: 0.3))
        #expect(processor.drainNew().count == 30)
    }

    /// Device hot-swap mid-recording changes the tap format; the converter
    /// rebuilds but the sample store — and the drainNew cursor — carry on.
    @Test func cursorSurvivesFormatChange() {
        let processor = TapProcessor(targetSampleRate: 16_000)
        processor.process(Self.buffer(frames: 100, value: 0.1))
        #expect(processor.drainNew().count == 100)

        // Same content at 48 kHz mono: resampler rebuilds, cursor holds.
        let format48 = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: 1, interleaved: false
        )!
        let buffer48 = AVAudioPCMBuffer(pcmFormat: format48, frameCapacity: 4800)!
        let channel = buffer48.floatChannelData![0]
        for i in 0..<4800 { channel[i] = 0.2 }
        buffer48.frameLength = 4800

        processor.process(buffer48)
        let fresh = processor.drainNew()
        // 4800 frames at 48 kHz ≈ 1600 at 16 kHz (resampler edge slop OK).
        #expect(abs(fresh.count - 1600) < 100)
        #expect(processor.drain().count == 100 + fresh.count)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/kal/fabulous && swift test --filter TapProcessorDrainNewTests`
Expected: compile error — `drainNew` not defined.

- [ ] **Step 3: Implement `drainNew` in TapProcessor**

In `Sources/AudioCapture/TapProcessor.swift`, add a cursor field next to `samples`:

```swift
    private var samples: [Float] = []
    /// Index of the first sample not yet returned by `drainNew()`.
    private var newCursor = 0
```

Add after `drain()` (and make `drain()` reset the cursor):

```swift
    /// Removes and returns everything accumulated so far.
    func drain() -> [Float] {
        lock.lock()
        let drained = samples
        samples = []
        newCursor = 0
        lock.unlock()
        return drained
    }

    /// Returns samples accumulated since the previous `drainNew()` call
    /// without removing anything — `drain()` still sees the full utterance.
    /// Feeds the live transcription session while recording.
    func drainNew() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard newCursor < samples.count else { return [] }
        let fresh = Array(samples[newCursor...])
        newCursor = samples.count
        return fresh
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/kal/fabulous && swift test --filter TapProcessorDrainNewTests`
Expected: 4 tests PASS.

- [ ] **Step 5: Add recorder pass-throughs and the untrimmed stop**

In `Sources/AudioCapture/AudioRecorder.swift`, replace `stop()` with:

```swift
    /// Stops capturing and returns the recorded audio. With `trimming` (the
    /// default) leading/trailing silence is VAD-trimmed; `trimming: false`
    /// returns the raw buffer — the streaming path never uses the trimmed
    /// audio, and running the VAD at release would reintroduce the latency
    /// streaming removes. Returns an empty buffer if nothing was heard.
    /// (Qualified name: CoreAudio declares an unrelated `AudioBuffer`.)
    public func stop(trimming: Bool = true) -> FabCore.AudioBuffer {
        guard isRecording else {
            return FabCore.AudioBuffer(samples: [], sampleRate: Self.targetSampleRate)
        }
        removeObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false

        var raw = tapProcessor?.drain() ?? []
        tapProcessor = nil
        guard trimming else {
            return FabCore.AudioBuffer(samples: raw, sampleRate: Self.targetSampleRate)
        }
        let trimmed = vad.trimSilence(raw, sampleRate: Self.targetSampleRate)
        // Zero the untrimmed copy; the caller owns (and zeroes) the trimmed one.
        for i in raw.indices { raw[i] = 0 }
        return FabCore.AudioBuffer(samples: trimmed, sampleRate: Self.targetSampleRate)
    }

    /// Samples accumulated since the last poll, for feeding a streaming
    /// transcription session while recording. Empty when not recording.
    public func pollNewSamples() -> [Float] {
        tapProcessor?.drainNew() ?? []
    }

    /// VAD-trims an already-captured buffer — the lazy trim for the batch
    /// fallback after an untrimmed `stop`.
    public func trimSilence(_ audio: FabCore.AudioBuffer) -> FabCore.AudioBuffer {
        FabCore.AudioBuffer(
            samples: vad.trimSilence(audio.samples, sampleRate: audio.sampleRate),
            sampleRate: audio.sampleRate
        )
    }
```

- [ ] **Step 6: Build and run the full test suite**

Run: `cd /Users/kal/fabulous && swift build --arch arm64 && swift test`
Expected: zero warnings, all tests pass (existing `stop()` call sites still compile via the default parameter).

- [ ] **Step 7: Commit**

```bash
git add Sources/AudioCapture Tests/AudioCaptureTests
git commit -m "AudioCapture: incremental drainNew cursor, untrimmed stop, lazy trim"
```

---

### Task 2: `DictationMetrics.streamed` (FabCore)

**Files:**
- Modify: `Sources/FabCore/DictationMetrics.swift`
- Test: `Tests/FabCoreTests/DictationMetricsStreamedTests.swift` (create)

**Interfaces:**
- Produces: `DictationMetrics.streamed: Bool` (init parameter, default `false`); `logLine` ends with `" streamed"` when true.

- [ ] **Step 1: Write the failing test**

Create `Tests/FabCoreTests/DictationMetricsStreamedTests.swift`:

```swift
import Foundation
import Testing

@testable import FabCore

@Suite struct DictationMetricsStreamedTests {
    private func metrics(streamed: Bool) -> DictationMetrics {
        DictationMetrics(
            audioDuration: 2.0,
            stopAndTrim: .milliseconds(20),
            transcription: .milliseconds(300),
            postProcessing: .milliseconds(1),
            delivery: .milliseconds(30),
            total: .milliseconds(351),
            streamed: streamed
        )
    }

    @Test func streamedDefaultsToFalse() {
        let m = DictationMetrics(
            audioDuration: 1, stopAndTrim: .zero, transcription: .zero,
            postProcessing: .zero, delivery: .zero, total: .zero
        )
        #expect(m.streamed == false)
    }

    @Test func logLineMarksStreamedDictations() {
        #expect(metrics(streamed: true).logLine.hasSuffix(" streamed"))
        #expect(!metrics(streamed: false).logLine.contains("streamed"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/kal/fabulous && swift test --filter DictationMetricsStreamedTests`
Expected: compile error — no `streamed` parameter.

- [ ] **Step 3: Implement**

In `Sources/FabCore/DictationMetrics.swift`:

Add the stored property after `total`:

```swift
    /// Hotkey release → text delivered.
    public var total: Duration
    /// True when the audio was fed to the engine live during recording, so
    /// `transcription` is just the finalize wait (phase-5 streaming path).
    public var streamed: Bool
```

Extend the initializer (new parameter last, defaulted, so existing call sites compile):

```swift
    public init(
        audioDuration: TimeInterval,
        stopAndTrim: Duration,
        transcription: Duration,
        postProcessing: Duration,
        delivery: Duration,
        total: Duration,
        streamed: Bool = false
    ) {
        self.audioDuration = audioDuration
        self.stopAndTrim = stopAndTrim
        self.transcription = transcription
        self.postProcessing = postProcessing
        self.delivery = delivery
        self.total = total
        self.streamed = streamed
    }
```

Append the marker in `logLine` (replace the existing property):

```swift
    /// Full breakdown for the log.
    public var logLine: String {
        "dictation metrics: total=\(Self.seconds(total))"
            + " stop+vad=\(Self.seconds(stopAndTrim))"
            + " asr=\(Self.seconds(transcription))"
            + " post=\(Self.seconds(postProcessing))"
            + " delivery=\(Self.seconds(delivery))"
            + " audio=\(String(format: "%.2f", audioDuration))s"
            + (streamed ? " streamed" : "")
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/kal/fabulous && swift test --filter DictationMetricsStreamedTests`
Expected: 2 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FabCore/DictationMetrics.swift Tests/FabCoreTests/DictationMetricsStreamedTests.swift
git commit -m "FabCore: DictationMetrics.streamed flag"
```

---

### Task 3: `streamed` column + v3 migration (HistoryStore)

**Files:**
- Modify: `Sources/HistoryStore/HistoryStore.swift`
- Test: `Tests/HistoryStoreTests/MetricsStreamedTests.swift` (create)

**Interfaces:**
- Consumes: existing `MetricsEntry`, `HistoryStore.recordMetrics`, `HistoryStore.inMemory()`.
- Produces: `MetricsEntry.streamed: Bool` (init parameter, default `false`); GRDB migration `v3-metrics-streamed` adding a NOT NULL `streamed` column defaulting to `false` (old rows read back as `false`).

- [ ] **Step 1: Write the failing test**

Create `Tests/HistoryStoreTests/MetricsStreamedTests.swift`:

```swift
import Foundation
import Testing

@testable import HistoryStore

@Suite struct MetricsStreamedTests {
    private func entry(streamed: Bool) -> MetricsEntry {
        MetricsEntry(
            createdAt: Date(),
            engineID: "apple-speech",
            audioSeconds: 2.0,
            stopTrimMs: 20,
            asrMs: 300,
            postMs: 1,
            deliveryMs: 30,
            totalMs: 351,
            streamed: streamed
        )
    }

    @Test func streamedRoundTrips() throws {
        let store = try HistoryStore.inMemory()
        try store.recordMetrics(entry(streamed: true))
        try store.recordMetrics(entry(streamed: false))
        let stats = try store.latencyStats(engineID: "apple-speech")
        #expect(stats?.sampleCount == 2)
    }

    @Test func streamedDefaultsToFalse() {
        let e = MetricsEntry(
            createdAt: Date(), engineID: "x", audioSeconds: 1,
            stopTrimMs: 1, asrMs: 1, postMs: 1, deliveryMs: 1, totalMs: 4
        )
        #expect(e.streamed == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/kal/fabulous && swift test --filter MetricsStreamedTests`
Expected: compile error — no `streamed` parameter on `MetricsEntry`.

- [ ] **Step 3: Implement**

In `Sources/HistoryStore/HistoryStore.swift`:

Add to `MetricsEntry` after `totalMs`:

```swift
    public var totalMs: Double
    /// True when the audio was streamed to the engine during recording
    /// (phase 5); keeps p50/p90 comparisons across the change honest.
    public var streamed: Bool
```

Extend its initializer (defaulted last parameter):

```swift
    public init(
        id: Int64? = nil,
        createdAt: Date,
        engineID: String,
        audioSeconds: Double,
        stopTrimMs: Double,
        asrMs: Double,
        postMs: Double,
        deliveryMs: Double,
        totalMs: Double,
        streamed: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.engineID = engineID
        self.audioSeconds = audioSeconds
        self.stopTrimMs = stopTrimMs
        self.asrMs = asrMs
        self.postMs = postMs
        self.deliveryMs = deliveryMs
        self.totalMs = totalMs
        self.streamed = streamed
    }
```

Register the migration in `migrator`, after the `v2-create-dictation-metrics` block:

```swift
        migrator.registerMigration("v3-metrics-streamed") { db in
            try db.alter(table: MetricsEntry.databaseTableName) { t in
                t.add(column: "streamed", .boolean).notNull().defaults(to: false)
            }
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/kal/fabulous && swift test --filter MetricsStreamedTests && swift test --filter HistoryStore`
Expected: new tests PASS; existing HistoryStore tests still PASS (Codable picks up the new column automatically).

- [ ] **Step 5: Commit**

```bash
git add Sources/HistoryStore/HistoryStore.swift Tests/HistoryStoreTests/MetricsStreamedTests.swift
git commit -m "HistoryStore: streamed metrics column (v3 migration)"
```

---

### Task 4: Streaming protocols + fallback helper + pipeline tests (TranscriptionEngine)

**Files:**
- Create: `Sources/TranscriptionEngine/StreamingTranscription.swift`
- Test: `Tests/PipelineTests/StreamingPipelineTests.swift` (create)

**Interfaces:**
- Consumes: `TranscriptionBackend`, `Transcript`, `FabCore.AudioBuffer`.
- Produces (Task 5 conforms to these; Task 7 calls them — exact signatures):

```swift
public protocol StreamingSession: Sendable {
    func feed(_ samples: [Float]) async
    var partials: AsyncStream<String> { get }
    func finish() async throws -> Transcript
    func cancel() async
}

public protocol StreamingTranscriptionBackend: TranscriptionBackend {
    func startStreamingSession() async throws -> any StreamingSession
}

public enum StreamingDictation {
    public static func finalTranscript(
        session: (any StreamingSession)?,
        fallback: @Sendable () async throws -> Transcript
    ) async throws -> (transcript: Transcript, streamed: Bool)
}
```

- [ ] **Step 1: Write the failing tests**

Create `Tests/PipelineTests/StreamingPipelineTests.swift`:

```swift
import AVFoundation
import FabCore
import Foundation
import Testing

@testable import AudioCapture
@testable import TranscriptionEngine

/// Streaming-path seams: session text wins over batch, every failure mode
/// falls back to batch, feeds flow through the drainNew cursor in order.
@Suite struct StreamingPipelineTests {
    actor FakeSession: StreamingSession {
        private(set) var fed: [[Float]] = []
        private(set) var cancelled = false
        private(set) var finished = false
        let finishResult: Result<Transcript, Error>
        nonisolated let partials: AsyncStream<String>
        private let partialsContinuation: AsyncStream<String>.Continuation

        init(finishResult: Result<Transcript, Error>) {
            self.finishResult = finishResult
            (partials, partialsContinuation) = AsyncStream.makeStream()
        }

        func feed(_ samples: [Float]) {
            guard !finished, !cancelled else { return }
            fed.append(samples)
            partialsContinuation.yield("partial \(fed.count)")
        }

        func finish() throws -> Transcript {
            finished = true
            partialsContinuation.finish()
            return try finishResult.get()
        }

        func cancel() {
            cancelled = true
            partialsContinuation.finish()
        }
    }

    struct SessionDied: Error {}

    private static func batchTranscript() -> Transcript {
        Transcript(text: "batch text", audioDuration: 1)
    }

    @Test func sessionTranscriptWinsAndBatchIsSkipped() async throws {
        let session = FakeSession(
            finishResult: .success(Transcript(text: "streamed text", audioDuration: 1))
        )
        nonisolated(unsafe) var batchRan = false
        let (transcript, streamed) = try await StreamingDictation.finalTranscript(
            session: session,
            fallback: {
                batchRan = true
                return Self.batchTranscript()
            }
        )
        #expect(transcript.text == "streamed text")
        #expect(streamed)
        #expect(!batchRan)
    }

    @Test func finishFailureFallsBackToBatch() async throws {
        let session = FakeSession(finishResult: .failure(SessionDied()))
        let (transcript, streamed) = try await StreamingDictation.finalTranscript(
            session: session,
            fallback: { Self.batchTranscript() }
        )
        #expect(transcript.text == "batch text")
        #expect(!streamed)
        // The dead session was cancelled, not leaked.
        #expect(await session.cancelled)
    }

    @Test func missingSessionFallsBackToBatch() async throws {
        let (transcript, streamed) = try await StreamingDictation.finalTranscript(
            session: nil,
            fallback: { Self.batchTranscript() }
        )
        #expect(transcript.text == "batch text")
        #expect(!streamed)
    }

    @Test func feedAfterFinishIsIgnored() async throws {
        let session = FakeSession(
            finishResult: .success(Transcript(text: "t", audioDuration: 0))
        )
        await session.feed([0.1])
        _ = try await session.finish()
        await session.feed([0.2])
        #expect(await session.fed.count == 1)
    }

    /// Capture → drainNew → feed: chunks arrive in order and cover exactly
    /// what was captured, mirroring the AppController feed loop.
    @Test func drainNewFeedsChunksInOrder() async {
        let session = FakeSession(
            finishResult: .success(Transcript(text: "", audioDuration: 0))
        )
        let processor = TapProcessor(targetSampleRate: 16_000)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false
        )!
        for chunkValue in [Float(0.1), 0.2, 0.3] {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
            let channel = buffer.floatChannelData![0]
            for i in 0..<100 { channel[i] = chunkValue }
            buffer.frameLength = 100
            processor.process(buffer)
            await session.feed(processor.drainNew())
        }
        let fed = await session.fed
        #expect(fed.count == 3)
        #expect(fed.map(\.count) == [100, 100, 100])
        #expect(abs(fed[2][0] - 0.3) < 0.001)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/kal/fabulous && swift test --filter StreamingPipelineTests`
Expected: compile error — `StreamingSession` / `StreamingDictation` not defined.

- [ ] **Step 3: Implement the protocols and helper**

Create `Sources/TranscriptionEngine/StreamingTranscription.swift`:

```swift
import FabCore
import Foundation

/// A live transcription session for one utterance: audio is fed in chunks
/// while the user is still speaking, so most decoding overlaps recording
/// and `finish()` is just the finalize wait.
public protocol StreamingSession: Sendable {
    /// Appends 16 kHz mono Float32 samples captured since the last feed.
    /// Calls arriving after `finish()`/`cancel()` began are ignored — the
    /// feed timer races the stop path by design.
    func feed(_ samples: [Float]) async

    /// Best transcript so far (finalized pieces + volatile tail), a fresh
    /// full string per update. Finishes when the session ends.
    var partials: AsyncStream<String> { get }

    /// Signals end of audio and waits for the final decode.
    func finish() async throws -> Transcript

    /// Abandons the session. Safe to call at any time, including after
    /// `finish()` failed.
    func cancel() async
}

/// A backend that can transcribe live during recording. `AppController`
/// detects capability with a runtime conformance check; WhisperKit stays
/// batch-only.
public protocol StreamingTranscriptionBackend: TranscriptionBackend {
    /// Opens a session for one utterance. Throws if the engine isn't ready
    /// (e.g. `load` hasn't succeeded).
    func startStreamingSession() async throws -> any StreamingSession
}

/// The fallback invariant in one place: use the streaming result when the
/// session survived, otherwise run the batch path — a transcript is never
/// silently lost.
public enum StreamingDictation {
    public static func finalTranscript(
        session: (any StreamingSession)?,
        fallback: @Sendable () async throws -> Transcript
    ) async throws -> (transcript: Transcript, streamed: Bool) {
        if let session {
            do {
                return (try await session.finish(), true)
            } catch {
                await session.cancel()
                // Fall through to batch; the caller still has the full buffer.
            }
        }
        return (try await fallback(), false)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/kal/fabulous && swift test --filter StreamingPipelineTests`
Expected: 5 tests PASS.

- [ ] **Step 5: Build everything, commit**

Run: `cd /Users/kal/fabulous && swift build --arch arm64 && swift test`
Expected: zero warnings, all green.

```bash
git add Sources/TranscriptionEngine/StreamingTranscription.swift Tests/PipelineTests/StreamingPipelineTests.swift
git commit -m "TranscriptionEngine: streaming session protocol + fallback helper"
```

---

### Task 5: SpeechAnalyzer streaming session

**Files:**
- Modify: `Sources/TranscriptionEngine/SpeechAnalyzerBackend.swift`
- Test: `Tests/TranscriptionEngineTests/SpeechAnalyzerBackendTests.swift` (append a conditional test — look at the existing `FAB_REAL_ASR` tests in that file and follow their skip/audio-synthesis pattern exactly)

**Interfaces:**
- Consumes: Task 4's `StreamingSession` / `StreamingTranscriptionBackend`.
- Produces: `SpeechAnalyzerBackend: StreamingTranscriptionBackend`; `startStreamingSession()` throws `TranscriptionError.modelNotLoaded` before `load`.

**Background you need:** `SpeechAnalyzer` modules are single-use — one transcriber+analyzer pair per utterance (same as the existing batch `transcribe`). The batch path subscribes to `transcriber.results` and filters `result.isFinal`; volatile (non-final) results only arrive when the transcriber is created with volatile reporting enabled. The existing batch code in this file shows the exact `AnalyzerInput` / `analyzeSequence` / `finalizeAndFinish` choreography — the session is that choreography stretched over the utterance instead of run at the end.

- [ ] **Step 1: Implement the session actor**

Add to `Sources/TranscriptionEngine/SpeechAnalyzerBackend.swift` (below the backend actor, same file — it shares the audio plumbing helpers):

```swift
/// One live utterance against SpeechAnalyzer: input stream held open,
/// volatile results forwarded as partials, `finish()` = finalize wait.
@available(macOS 26.0, *)
actor SpeechAnalyzerStreamingSession: StreamingSession {
    nonisolated let partials: AsyncStream<String>
    private let partialsContinuation: AsyncStream<String>.Continuation

    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let analyzeTask: Task<Void, Error>
    private let collector: Task<String, Error>

    /// Total samples fed, for the transcript's audioDuration.
    private var fedSampleCount = 0
    private var fedSampleRate: Double = AudioConstants.expectedSampleRate
    private var ended = false

    /// 16 kHz mono Float32 — what the capture pipeline produces.
    private enum AudioConstants {
        static let expectedSampleRate: Double = 16_000
    }

    init(locale: Locale, options: SpeechAnalyzer.Options) async throws {
        // Volatile results on: partials are the point of a live session.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        guard
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber]
            )
        else {
            throw SpeechAnalyzerBackendError.audioConversionFailed
        }
        analyzerFormat = format

        (partials, partialsContinuation) = AsyncStream.makeStream()

        // Finalized pieces accumulate; the volatile tail is replaced on
        // every non-final result. Each update emits the full string so far.
        let continuation = partialsContinuation
        collector = Task {
            var pieces: [String] = []
            var volatileTail = ""
            for try await result in transcriber.results {
                let piece = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if result.isFinal {
                    if !piece.isEmpty { pieces.append(piece) }
                    volatileTail = ""
                } else {
                    volatileTail = piece
                }
                let current = (pieces + (volatileTail.isEmpty ? [] : [volatileTail]))
                    .joined(separator: " ")
                continuation.yield(current)
            }
            return pieces.joined(separator: " ")
        }

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        input = inputBuilder
        let analyzerRef = analyzer
        analyzeTask = Task {
            _ = try await analyzerRef.analyzeSequence(inputSequence)
        }
    }

    func feed(_ samples: [Float]) {
        guard !ended, !samples.isEmpty else { return }
        let chunk = FabCore.AudioBuffer(
            samples: samples, sampleRate: AudioConstants.expectedSampleRate
        )
        guard
            let source = SpeechAnalyzerBackend.pcmBuffer(from: chunk),
            let converted = SpeechAnalyzerBackend.convert(source, to: analyzerFormat)
        else {
            // A malformed chunk shouldn't kill the utterance; skip it and
            // let the batch fallback cover any resulting quality gap.
            return
        }
        fedSampleCount += samples.count
        input.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async throws -> Transcript {
        guard !ended else { throw TranscriptionError.modelNotLoaded }
        ended = true
        input.finish()
        do {
            try await analyzeTask.value
            try await analyzer.finalizeAndFinish(through: .infinity)
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            partialsContinuation.finish()
            throw error
        }
        let text = try await collector.value
        partialsContinuation.finish()
        return Transcript(
            text: text,
            audioDuration: Double(fedSampleCount) / fedSampleRate
        )
    }

    func cancel() async {
        guard !ended else { return }
        ended = true
        input.finish()
        collector.cancel()
        await analyzer.cancelAndFinishNow()
        partialsContinuation.finish()
    }
}
```

Then make the backend conform. Change the declaration line:

```swift
public actor SpeechAnalyzerBackend: TranscriptionBackend {
```

to:

```swift
public actor SpeechAnalyzerBackend: StreamingTranscriptionBackend {
```

and add the factory method to the backend:

```swift
    public func startStreamingSession() async throws -> any StreamingSession {
        guard let locale = loadedLocale else { throw TranscriptionError.modelNotLoaded }
        return try await SpeechAnalyzerStreamingSession(
            locale: locale, options: Self.analyzerOptions
        )
    }
```

Finally, widen access on the two audio helpers the session reuses — change `private static func pcmBuffer` and `private static func convert` to `static func pcmBuffer` / `static func convert` (internal).

**Expected friction (check the SDK, don't guess):** `SpeechTranscriber`'s initializer labels, the volatile-results option name, and `finalizeAndFinish(through:)`'s argument type (it takes a `CMTime`-like position — the batch path passes the value returned by `analyzeSequence`; if `.infinity` doesn't compile, capture `analyzeTask`'s return value as `Task<CMTime?, Error>` and pass it through, mirroring the batch code exactly). Resolve against the macOS 26 SDK headers; the batch `transcribe` in this same file is the working reference for every one of these calls.

- [ ] **Step 2: Build**

Run: `cd /Users/kal/fabulous && swift build --arch arm64`
Expected: compiles, zero warnings. Iterate on SDK signatures per the note above until clean.

- [ ] **Step 3: Add the conditional real-engine test**

`Tests/TranscriptionEngineTests/SpeechAnalyzerBackendTests.swift` already has the gating pattern (`.enabled(if: ProcessInfo.processInfo.environment["FAB_REAL_ASR"] == "1")` plus an `#available(macOS 26.0, *)` guard), `say`-based synthesis inline in the test, and a `monoFloatBuffer(from:)` helper. Append this test to the suite:

```swift
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FAB_REAL_ASR"] == "1"))
    func streamingSessionYieldsPartialsBeforeFinish() async throws {
        guard #available(macOS 26.0, *) else { return }

        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("fab-stream-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = [
            "-o", wav.path, "--data-format=LEF32@16000",
            "hello world this is a streaming dictation test",
        ]
        try say.run()
        say.waitUntilExit()
        #expect(say.terminationStatus == 0)
        let audio = try Self.monoFloatBuffer(from: wav)

        let backend = SpeechAnalyzerBackend()
        try await backend.load(model: .appleSpeech)
        let session = try await backend.startStreamingSession()

        let partialCount = Task {
            var count = 0
            for await _ in session.partials { count += 1 }
            return count
        }
        // Feed in ~250 ms chunks, the AppController cadence.
        let chunkSize = 4000  // 0.25 s at 16 kHz
        var offset = 0
        while offset < audio.samples.count {
            let end = min(offset + chunkSize, audio.samples.count)
            await session.feed(Array(audio.samples[offset..<end]))
            offset = end
        }
        let transcript = try await session.finish()

        let lowered = transcript.text.lowercased()
        #expect(lowered.contains("hello"))
        #expect(lowered.contains("dictation"))
        #expect(abs(transcript.audioDuration - audio.duration) < 0.1)
        // Volatile results flowed while (or before) finalizing.
        #expect(await partialCount.value > 0)
    }
```

- [ ] **Step 4: Run the real-engine test**

Run: `cd /Users/kal/fabulous && FAB_REAL_ASR=1 swift test --filter SpeechAnalyzerBackendTests`
Expected: PASS (or SKIP on machines without the OS assets — same behavior as the existing tests). Also run plain `swift test` and expect the suite to skip cleanly.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranscriptionEngine/SpeechAnalyzerBackend.swift Tests/TranscriptionEngineTests/SpeechAnalyzerBackendTests.swift
git commit -m "SpeechAnalyzer: live streaming session with volatile partials"
```

---

### Task 6: Overlay partial-text line

**Files:**
- Modify: `Sources/FabulousApp/OverlayController.swift`

**Interfaces:**
- Consumes: existing `OverlayModel` / `OverlayView` / `CapsuleChrome`.
- Produces (Task 7 calls these): `OverlayController.updatePartial(_ text: String)`; `showRecording()` clears any previous partial.

No unit tests — SwiftUI view code in the executable target (repo convention: overlay is verified by eye). Build must stay warning-free.

- [ ] **Step 1: Add partial text to the model and controller**

In `OverlayModel`, add below `level`:

```swift
    /// Live partial transcript while streaming (empty = hidden). Raw engine
    /// output — post-processing only runs on the final text.
    var partialText: String = ""
```

In `OverlayController`, clear it in `showRecording()`:

```swift
    func showRecording() {
        model.phase = .recording
        model.level = 0
        model.partialText = ""
        show()
    }
```

and add next to `updateLevel`:

```swift
    /// Streams the live partial transcript into the recording pill.
    func updatePartial(_ text: String) {
        guard model.phase == .recording else { return }
        model.partialText = text
    }
```

- [ ] **Step 2: Render the partial line**

In `OverlayView`, replace the `.recording` case:

```swift
            case .recording:
                CapsuleChrome(energy: CGFloat(min(1, model.level))) {
                    VStack(spacing: 5) {
                        SiriWave(level: model.level, energetic: true)
                            .frame(width: 96, height: 26)
                        if !model.partialText.isEmpty {
                            Text(model.partialText)
                                .font(.caption)
                                .foregroundStyle(OverlayStyle.ice.opacity(0.75))
                                .lineLimit(1)
                                .truncationMode(.head)   // tail of speech wins
                                .frame(maxWidth: 280)
                                .transition(.opacity)
                        }
                    }
                }
```

(`truncationMode(.head)` keeps the newest words visible — the spec's "tail-truncated" pill. The capsule grows to fit via its padding; the 360×72 stage has room.)

- [ ] **Step 3: Build**

Run: `cd /Users/kal/fabulous && swift build --arch arm64`
Expected: zero warnings.

- [ ] **Step 4: Commit**

```bash
git add Sources/FabulousApp/OverlayController.swift
git commit -m "Overlay: live partial-transcript line in the recording pill"
```

---

### Task 7: AppController wiring

**Files:**
- Modify: `Sources/FabulousApp/AppController.swift`

**Interfaces:**
- Consumes: everything above — `pollNewSamples()`, `stop(trimming:)`, `trimSilence(_:)`, `StreamingTranscriptionBackend`, `startStreamingSession()`, `StreamingDictation.finalTranscript`, `updatePartial(_:)`, `DictationMetrics(streamed:)`, `MetricsEntry(streamed:)`.
- Produces: the user-visible feature. No new public API.

The logic here was already proven in Task 4's pipeline tests; this task is wiring, ordered exactly as below. The session/task fields must be cleaned up on *every* exit path — recording, cancel, short utterance, error.

- [ ] **Step 1: Add state fields**

Next to `levelTask`:

```swift
    private var levelTask: Task<Void, Never>?
    /// Live streaming session for the current utterance (Apple Speech only).
    private var streamingSession: (any StreamingSession)?
    /// Creates the session off the critical path of `beginRecording`.
    private var sessionStartTask: Task<Void, Never>?
    /// Forwards session partials to the overlay.
    private var partialsTask: Task<Void, Never>?
```

- [ ] **Step 2: Start the session concurrently in `beginRecording`**

After `startLevelUpdates()` in `beginRecording()`, add:

```swift
            startStreamingSessionIfAvailable()
```

and add the method (near the push-to-talk section):

```swift
    /// Opens a live session when the selected engine supports it. Runs
    /// concurrently so recording start is never delayed; samples accumulate
    /// in the tap and the first feed catches up via the drainNew cursor.
    /// Failure is silent — the batch path is untouched and always works.
    private func startStreamingSessionIfAvailable() {
        guard settings.transcriptionEngine == .appleSpeech,
              let streamingBackend = backend as? any StreamingTranscriptionBackend
        else { return }
        sessionStartTask = Task { [weak self] in
            do {
                let session = try await streamingBackend.startStreamingSession()
                guard let self, state == .recording else {
                    await session.cancel()
                    return
                }
                streamingSession = session
                partialsTask = Task { [weak self] in
                    for await partial in session.partials {
                        guard !Task.isCancelled else { return }
                        self?.overlay.updatePartial(partial)
                    }
                }
            } catch {
                NSLog("fabulous: streaming session unavailable, batch path (\(error))")
            }
        }
    }
```

- [ ] **Step 3: Feed from the level loop**

Replace `startLevelUpdates()`:

```swift
    private func startLevelUpdates() {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                let level = await recorder.currentLevel
                overlay.updateLevel(level)
                // Every 5th tick (~250 ms): feed fresh samples to the live
                // session. The session ignores feeds after finish/cancel.
                tick += 1
                if tick % 5 == 0, let session = streamingSession {
                    let fresh = await recorder.pollNewSamples()
                    if !fresh.isEmpty { await session.feed(fresh) }
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
```

- [ ] **Step 4: Tear down streaming state on every exit**

Add the helper:

```swift
    /// Stops the feed/partials machinery. Runs before any overlay
    /// transition so a late partial can never repaint a hidden pill.
    /// Returns the live session (if any) for finish/cancel; clears fields.
    private func takeStreamingSession() async -> (any StreamingSession)? {
        sessionStartTask?.cancel()
        // Let a mid-flight start finish or observe cancellation before we
        // read the field, so a session can't appear after we've looked.
        await sessionStartTask?.value
        sessionStartTask = nil
        partialsTask?.cancel()
        partialsTask = nil
        let session = streamingSession
        streamingSession = nil
        return session
    }
```

In `cancelRecording()`, after `stopLevelUpdates()`:

```swift
        if let session = await takeStreamingSession() { await session.cancel() }
```

- [ ] **Step 5: Rework `finishRecording`**

Replace the body from `var audio = await recorder.stop()` through the `catch` with:

```swift
        let session = await takeStreamingSession()
        // Streaming path: stop untrimmed — the trimmed buffer would go
        // unused and Silero at release costs exactly the latency this
        // phase removes. Trim lazily only if we fall back to batch.
        var audio = await recorder.stop(trimming: session == nil)
        defer { audio.zero() }
        let stoppedAt = clock.now

        guard audio.duration >= minimumUtteranceDuration else {
            if let session { await session.cancel() }
            state = .idle
            overlay.hide()
            return
        }
        state = .transcribing
        overlay.showTranscribing()
        do {
            let capturedAudio = audio
            let (transcript, streamed) = try await StreamingDictation.finalTranscript(
                session: session,
                fallback: { [recorder, backend] in
                    var trimmed = await recorder.trimSilence(capturedAudio)
                    defer { trimmed.zero() }
                    guard !trimmed.isEmpty else {
                        return Transcript(text: "", audioDuration: 0)
                    }
                    return try await backend.transcribe(trimmed, language: nil)
                }
            )
            let transcribedAt = clock.now
            let text = try await postProcessor.process(transcript.text)
            let processedAt = clock.now
            guard !text.isEmpty else {
                state = .idle
                overlay.hide()
                return
            }
            lastTranscript = text
            statusItem.setLastTranscriptAvailable(true)
            recordHistory(text: text, audioSeconds: transcript.audioDuration)

            await deliver(text)
            let deliveredAt = clock.now

            state = .idle
            noteMetrics(DictationMetrics(
                audioDuration: transcript.audioDuration,
                stopAndTrim: stoppedAt - releasedAt,
                transcription: transcribedAt - stoppedAt,
                postProcessing: processedAt - transcribedAt,
                delivery: deliveredAt - processedAt,
                total: deliveredAt - releasedAt,
                streamed: streamed
            ))
        } catch {
            overlay.hide()
            await flashFailure("Transcription failed: \(error)")
        }
```

Notes for the implementer:
- `audio.duration` guard now sees the *raw* duration in the streaming path — fine; the guard exists to catch accidental taps and raw ≥ trimmed.
- The batch path's empty-after-trim case previously exited before `transcribe`; the fallback closure preserves that by returning an empty transcript, and the existing `guard !text.isEmpty` turns it into today's silent no-op.
- History/metrics use `transcript.audioDuration` (what was actually transcribed) instead of the raw stop buffer's duration — in the batch path those are the trimmed duration, matching today's behavior.
- If the compiler objects to capturing `backend` (a computed property) in the closure list, bind `let batchBackend = backend` above the `do` and capture that.

- [ ] **Step 6: Persist the flag**

In `persistMetrics`, add the argument to the `MetricsEntry`:

```swift
                totalMs: DictationMetrics.milliseconds(metrics.total),
                streamed: metrics.streamed
```

- [ ] **Step 7: Build, full test suite**

Run: `cd /Users/kal/fabulous && swift build --arch arm64 && swift test`
Expected: zero warnings, all green.

- [ ] **Step 8: Commit**

```bash
git add Sources/FabulousApp/AppController.swift
git commit -m "AppController: stream dictation to SpeechAnalyzer while recording"
```

---

### Task 8: Manual verification + docs

**Files:**
- Modify: `CLAUDE.md` (State / roadmap section + a gotcha)
- Modify: `docs/specs/phase-5-streaming.md` (status line)

- [ ] **Step 1: Build the app bundle and dogfood**

```bash
cd /Users/kal/fabulous && scripts/build.sh && open build/fabulous.app
```

(If codesign fails with `errSecInternalComponent`, the dev keychain locked: `security unlock-keychain -p fabulous-dev-local ~/Library/Keychains/fabulous-dev.keychain-db` and re-run.)

Verify by hand, in Settings → General with engine = Apple Speech:
1. Hold hotkey, speak a long sentence — partial text appears in the pill while speaking, tail-truncated.
2. Release — injection lands near-instantly; menu "Last:" line shows small ASR time; log line ends with `streamed`.
3. Esc mid-recording — pill disappears, nothing injected.
4. Tap hotkey for <0.25 s — nothing happens, no leak (repeat dictation still works).
5. Switch engine to Whisper — behavior identical to before this phase (no partials, batch timing).
6. Dictate into a password field with Apple Speech — safety-net notice appears, transcript on clipboard.

- [ ] **Step 2: Update docs**

In `docs/specs/phase-5-streaming.md`, change the status line to `**Status:** implemented`.

In `CLAUDE.md`:
- Append to the *Done* list in "State / roadmap": phase 5 streaming (SpeechAnalyzer sessions feed live during recording, overlay partials, batch fallback, `streamed` metrics column).
- Remove "streaming transcription / partial results UI" from *Not yet built*.
- Add a gotcha bullet: streaming failures must degrade to the batch path over the full untrimmed buffer (`StreamingDictation.finalTranscript` is the seam); the streaming path stops the recorder with `trimming: false` — do not "fix" that back to a trimmed stop.

- [ ] **Step 3: Final full run + commit**

```bash
cd /Users/kal/fabulous && swift test && git add CLAUDE.md docs/specs/phase-5-streaming.md
git commit -m "docs: phase 5 streaming shipped"
```
