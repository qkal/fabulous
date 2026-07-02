import FabCore
import Foundation

/// A speech-to-text engine. Implementations are swappable:
///  - `WhisperKitBackend` (default): Whisper via CoreML on ANE/GPU.
///  - Parakeet via FluidAudio (planned): fast on 8 GB M1 machines.
///  - Apple `SpeechAnalyzer` (planned, macOS 26+): OS-managed assets.
public protocol TranscriptionBackend: Sendable {
    /// Downloads (if needed) and loads the model. Idempotent for the same
    /// descriptor. May take minutes on first run (download + CoreML
    /// specialization); callers should reflect that in UI.
    func load(model: ModelDescriptor) async throws

    /// Transcribes 16 kHz mono Float32 audio. `language: nil` means
    /// auto-detect. `onProgress` receives decode fractions (0…1) on the
    /// main actor while transcription runs, for progress UI.
    func transcribe(
        _ audio: AudioBuffer,
        language: Language?,
        onProgress: (@MainActor @Sendable (Double) -> Void)?
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
