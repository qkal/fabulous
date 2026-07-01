import FabCore
import Foundation

/// Energy-based voice activity detection.
///
/// This is the fallback VAD: frame-level RMS against a fixed threshold, used
/// to trim leading/trailing silence before transcription. A Silero VAD
/// (CoreML) can replace it behind the same trim function in a later phase.
public struct EnergyVAD: Sendable {
    /// Analysis frame length in seconds (30 ms is the conventional choice).
    public var frameDuration: Double
    /// RMS threshold above which a frame counts as speech.
    public var energyThreshold: Float
    /// Audio kept before the first / after the last active frame, in seconds,
    /// so plosives and trailing consonants are not clipped.
    public var padding: Double

    public init(
        frameDuration: Double = 0.03,
        energyThreshold: Float = 0.01,
        padding: Double = 0.15
    ) {
        self.frameDuration = frameDuration
        self.energyThreshold = energyThreshold
        self.padding = padding
    }

    /// Returns the input with leading and trailing silence removed.
    /// Returns an empty array when no frame exceeds the threshold —
    /// callers should skip transcription entirely in that case.
    public func trimSilence(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        let frameLength = max(1, Int(frameDuration * sampleRate))

        var firstActive: Int?
        var lastActive: Int?
        var frameIndex = 0
        var offset = 0
        while offset < samples.count {
            let end = min(offset + frameLength, samples.count)
            if rms(samples[offset..<end]) >= energyThreshold {
                if firstActive == nil { firstActive = frameIndex }
                lastActive = frameIndex
            }
            frameIndex += 1
            offset = end
        }

        guard let first = firstActive, let last = lastActive else { return [] }

        let pad = Int(padding * sampleRate)
        let start = max(0, first * frameLength - pad)
        let end = min(samples.count, (last + 1) * frameLength + pad)
        return Array(samples[start..<end])
    }

    private func rms(_ slice: ArraySlice<Float>) -> Float {
        guard !slice.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in slice {
            sum += sample * sample
        }
        return (sum / Float(slice.count)).squareRoot()
    }
}
