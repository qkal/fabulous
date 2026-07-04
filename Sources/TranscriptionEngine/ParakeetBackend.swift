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

    public func load(model: ModelDescriptor) async throws {
        guard model.id == ModelDescriptor.parakeetV3.id else {
            throw TranscriptionError.modelNotLoaded
        }
        if manager != nil { return }
        // `AsrModels.load(from:)` discards the last path component of
        // `from:` and re-derives it from `version.repo.folderName`
        // internally (Task 1 finding) — `repoRoot` already ends in
        // `v3FolderName` so this lines up with what `ParakeetInstaller`
        // downloaded to.
        let models = try await AsrModels.load(
            from: ParakeetLayout.repoRoot(ParakeetLayout.v3FolderName, downloadBase: modelsDirectory),
            configuration: AsrModels.defaultConfiguration(),
            version: .v3
        )
        let loaded = AsrManager(config: .default)
        try await loaded.loadModels(models)
        manager = loaded

        // Load the streaming model set too; a failure here degrades to
        // batch-only Parakeet (sessions just won't open) instead of failing
        // the whole engine.
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
            let streaming = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 600_000)
            try await streaming.loadModels(
                from: ParakeetLayout.repoRoot(ParakeetLayout.eouFolderName, downloadBase: modelsDirectory)
            )
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
            audio.samples, decoderState: &decoderState, language: fluidLanguage)
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
