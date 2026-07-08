import FabCore
import FluidAudio
// Scoped import, NOT `import FluidAudio` alone (Task 1 finding — see
// findings block): FluidAudio ships `public struct FluidAudio {}` as a
// deliberate namespace shim (`FluidAudioSwift.swift:29`, its own comment
// calls out the collision), which shadows `FluidAudio.Language` as "member
// `Language` of struct `FluidAudio`" instead of "the module's `Language`
// type" the moment both `FabCore` and `FluidAudio` are imported in the same
// file — `FluidAudio.Language(...)` fails to compile with "type 'FluidAudio'
// has no member 'Language'". This scoped import brings the module's
// `Language` enum into unqualified scope with the priority needed to
// disambiguate against `FabCore.Language`; empirically verified against a
// real FluidAudio v0.15.4 checkout in a throwaway SwiftPM package.
import enum FluidAudio.Language
import Foundation

/// NVIDIA Parakeet running on CoreML via FluidAudio.
///
/// Batch decode + streaming fallback use TDT 0.6b v3; live streaming
/// (Task 7) uses the separate EOU 120M model. Both model sets are
/// installed by `ParakeetInstaller` under `ParakeetLayout`'s roots;
/// FluidAudio only loads from there.
///
/// FluidAudio declares its own `Language`; always qualify `FabCore.Language`
/// in this file, and refer to FluidAudio's via the unqualified `Language`
/// name brought in by the `import enum FluidAudio.Language` line above (see
/// that comment for why `FluidAudio.Language` itself does not compile).
/// `AsrManager` and `StreamingEouAsrManager` (Task 7) are FluidAudio
/// `actor`s — Sendable by the language, no `@retroactive @unchecked
/// Sendable` workaround needed (Task 1 finding; unlike `WhisperKit`, which
/// is a plain `class`).
public actor ParakeetBackend: StreamingTranscriptionBackend {
    private var manager: AsrManager?
    /// The streaming (EOU 120M) engine, loaded once alongside the batch
    /// models and reset between utterances. One session at a time.
    private var streamingManager: StreamingEouAsrManager?
    private let modelsDirectory: URL

    public init(modelsDirectory: URL = FabPaths.modelsDirectory) {
        self.modelsDirectory = modelsDirectory
    }

    /// FluidAudio's batch decoder throws `invalidAudioData` on very short
    /// clips. The streaming→batch fallback can hand it a silence-trimmed buffer
    /// well under this; treat those as an empty utterance rather than a throw.
    ///
    /// NOTE (empirical, Task 6 repro): FluidAudio's real floor is a hard,
    /// exact-sample-count cliff, not a fuzzy acoustic threshold — a real
    /// `AsrManager.transcribe` repro against 16 kHz `say`-synthesized speech
    /// (3 phrases, sample counts swept in both coarse and 1-sample-fine
    /// steps) throws `invalidAudioData` at exactly 4799 samples (0.2999... s)
    /// and succeeds at exactly 4800 samples (0.300 s) on every trial,
    /// consistently — almost certainly an internal frame/window size
    /// requirement (4800 samples @ 16 kHz = 300 ms). The brief's original
    /// 0.16 s default sat well inside the throwing region and was raised to
    /// 0.30 s, the measured cliff, after this run.
    static let batchMinimumDuration: TimeInterval = 0.30

    /// FluidAudio's measured invalidAudioData cliff: exactly 4800 samples
    /// (0.300 s @ 16 kHz) — see the batchMinimumDuration NOTE above.
    static let batchFloorSamples = 4_800

    static func isBelowBatchMinimum(_ audio: FabCore.AudioBuffer) -> Bool {
        audio.duration < batchMinimumDuration
    }

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

    public func load(model: ModelDescriptor) async throws {
        guard model.id == ModelDescriptor.parakeetV3.id else {
            throw TranscriptionError.modelNotLoaded
        }
        if manager != nil {
            // Batch models are resident; retry the streaming set if its
            // first load failed transiently (degraded batch-only state).
            await loadStreamingModelsIfNeeded()
            return
        }
        // `AsrModels.load(from:)` discards the last path component of
        // `from:` and re-derives it from `version.repo.folderName`
        // internally (Task 1 finding) — `repoRoot` already ends in
        // `v3FolderName` so this lines up with what `ParakeetInstaller`
        // downloaded to.
        let v3Root = ParakeetLayout.repoRoot(ParakeetLayout.v3FolderName, downloadBase: modelsDirectory)
        // TOFU manifest check (F5): a mismatch does not hard-fail here —
        // `DownloadUtils.loadModels` (inside `AsrModels.load`) already
        // detects a CoreML model that fails to instantiate and deletes +
        // re-downloads it, so we log and still hand the directory to that
        // loader rather than duplicating its repair logic.
        if !ModelManifestStore.verify(root: v3Root, relativeComponents: ParakeetLayout.v3RequiredComponents) {
            NSLog("fabulous: parakeet v3 model manifest verification failed — attempting load anyway (FluidAudio auto-recovers corrupt files)")
        }
        let models = try await AsrModels.load(
            from: v3Root,
            configuration: AsrModels.defaultConfiguration(),
            version: .v3
        )
        let loaded = AsrManager(config: .default)
        try await loaded.loadModels(models)
        manager = loaded

        await loadStreamingModelsIfNeeded()
    }

    /// Loads the streaming (EOU 120M) model set if it isn't already resident.
    /// A failure here degrades to batch-only Parakeet (sessions just won't
    /// open) instead of failing the whole engine. Called both on a fresh
    /// `load()` and on a repeated `load()` so a transient failure can be
    /// retried without an engine switch.
    private func loadStreamingModelsIfNeeded() async {
        guard streamingManager == nil else { return }
        do {
            // Task 1 finding: `eouDebounceMs` is a plain `Int`, default
            // 1280, no compiled ceiling — 600_000 (10 min) is safely usable
            // and never fires mid-dictation; the hotkey ends utterances, not
            // silence detection. `loadModels(from:)` (Task 1 finding) loads
            // flat files directly from the given directory (no folderName
            // re-derivation, unlike the v3 ASR path) — it must directly
            // contain `streaming_encoder.mlmodelc`, `decoder.mlmodelc`,
            // `joint_decision.mlmodelc`, `vocab.json`, which is exactly what
            // `ParakeetLayout.repoRoot(eouFolderName, downloadBase:)` +
            // `ParakeetInstaller`'s `DownloadUtils.downloadRepo` produce.
            let eouRoot = ParakeetLayout.repoRoot(ParakeetLayout.eouFolderName, downloadBase: modelsDirectory)
            // Same TOFU check as the v3 tree above: log-only, then fall
            // through to `loadModels`, which performs its own corrupt-file
            // detection and re-download.
            if !ModelManifestStore.verify(root: eouRoot, relativeComponents: ParakeetLayout.eouRequiredComponents) {
                NSLog("fabulous: parakeet eou model manifest verification failed — attempting load anyway (FluidAudio auto-recovers corrupt files)")
            }
            let streaming = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 600_000)
            try await streaming.loadModels(from: eouRoot)
            streamingManager = streaming
        } catch {
            NSLog("fabulous: parakeet streaming models unavailable, batch-only (\(error))")
            streamingManager = nil
        }
    }

    public func transcribe(
        _ audio: FabCore.AudioBuffer,
        language: FabCore.Language?,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript {
        guard let manager else { throw TranscriptionError.modelNotLoaded }
        guard audio.sampleRate == 16_000 else {
            throw TranscriptionError.unsupportedSampleRate(audio.sampleRate)
        }
        guard !audio.isEmpty else {
            return Transcript(text: "", audioDuration: 0)
        }
        guard !Self.isBelowBatchMinimum(audio) else {
            return Transcript(text: "", audioDuration: audio.duration)
        }
        let decodable = Self.paddedToBatchFloor(audio)
        // No progress polling: v3 decodes at ~190× real time, so even a
        // minute of audio finishes inside one progress-UI repaint.
        // `language: nil` = auto-detect (there is no app language setting).
        //
        // Task 1 finding: every `AsrManager.transcribe` overload requires an
        // externalized `decoderState: inout TdtDecoderState` — there is no
        // zero-argument `transcribe(samples)`. A fresh `TdtDecoderState()`
        // per call is correct here: our batch path is one utterance per
        // call with no cross-utterance decoder state to carry (unlike
        // `ParakeetStreamingSession`, Task 7, which is inherently stateful
        // across chunks but owns its own FluidAudio-internal state instead).
        //
        // FluidAudio declares its own `Language` enum (distinct from
        // `FabCore.Language`, a RawRepresentable string wrapper) — bridge by
        // rawValue; an unrecognized/nil code falls through to FluidAudio's
        // auto-detect (nil), which is also our own "no hint" meaning.
        // Unqualified `Language` here resolves to FluidAudio's type via the
        // file's `import enum FluidAudio.Language` line — `FluidAudio.Language`
        // itself does NOT compile once `FabCore` is also imported (Task 1
        // finding, see the file-top comment).
        var decoderState = try TdtDecoderState()
        let fluidLanguage: Language? = language.flatMap { Language(rawValue: $0.rawValue) }
        let result = try await manager.transcribe(
            decodable.samples, decoderState: &decoderState, language: fluidLanguage)
        return Transcript(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            audioDuration: audio.duration
        )
    }

    public func startStreamingSession() async throws -> any StreamingSession {
        guard let streamingManager else { throw TranscriptionError.modelNotLoaded }
        return await ParakeetStreamingSession(manager: streamingManager)
    }

    public func unload() {
        manager = nil
        streamingManager = nil
    }
}
