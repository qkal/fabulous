import FabCore
import Foundation

/// A speech-to-text engine. Implementations are swappable:
///  - `WhisperKitBackend` (default): Whisper via CoreML on ANE/GPU.
///  - `ParakeetBackend` via FluidAudio: TDT v3 batch decoding, EOU 120M
///    streaming; fast on 8 GB M1 machines.
///  - `SpeechAnalyzerBackend` (macOS 26+): OS-managed assets.
public protocol TranscriptionBackend: Sendable {
    /// Downloads (if needed) and loads the model. Idempotent for the same
    /// descriptor. May take minutes on first run (download + CoreML
    /// specialization); callers should reflect that in UI.
    func load(model: ModelDescriptor) async throws

    /// Transcribes 16 kHz mono Float32 audio. `language: nil` means
    /// auto-detect. `onProgress` receives strictly increasing decode
    /// fractions (0…1) while transcription runs, for progress UI. It may
    /// be called from any executor; hop to the main actor at the call site
    /// (same contract as `ModelManager.download`).
    func transcribe(
        _ audio: AudioBuffer,
        language: Language?,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript

    /// Releases the loaded model (for the idle-unload memory policy).
    func unload() async
}

extension TranscriptionBackend {
    /// Progress-less convenience for callers and tests.
    public func transcribe(_ audio: AudioBuffer, language: Language?) async throws -> Transcript {
        try await transcribe(audio, language: language, onProgress: nil)
    }
}

public enum TranscriptionError: Error, Sendable {
    case modelNotLoaded
    case unsupportedSampleRate(Double)
}
