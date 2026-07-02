import Foundation

/// Trims leading/trailing silence from captured audio before transcription.
/// Two implementations: `EnergyVAD` (always available) and `SileroVAD`
/// (neural, needs its model on disk). `AudioRecorder` starts with energy
/// and is upgraded at runtime once the Silero model is installed.
///
/// (Named to avoid WhisperKit's `VoiceActivityDetector` class, per the
/// module-collision gotchas.)
public protocol VoiceActivityDetecting: Sendable {
    /// Returns the input minus leading/trailing silence; empty when no
    /// speech was detected at all (callers skip transcription then).
    func trimSilence(_ samples: [Float], sampleRate: Double) -> [Float]
}

extension EnergyVAD: VoiceActivityDetecting {}
