import CoreML
import Foundation

/// Silero VAD (CoreML build) — neural voice activity detection.
///
/// Runs the stateless 512-sample (32 ms @ 16 kHz) Silero model over the
/// recording and trims everything before the first and after the last
/// speech-probability peak. Compared to `EnergyVAD` it ignores keyboard
/// clatter, breaths, and room noise instead of treating them as speech.
///
/// The model file is not bundled; `SileroVADInstaller` (app layer) downloads
/// it. Any prediction failure falls back to the energy heuristic — trimming
/// must never lose a dictation.
public final class SileroVAD: @unchecked Sendable {
    // @unchecked: MLModel prediction is documented thread-safe, and the
    // MLMultiArray scratch buffer is created per call, not shared.

    public static let requiredSampleRate: Double = 16_000
    /// The model's fixed input length: 512 samples = 32 ms at 16 kHz.
    static let chunkLength = 512

    private let model: MLModel
    /// Speech probability at or above this marks a chunk as speech. Silero's
    /// conventional decision point is 0.5; trimming wants to err toward
    /// keeping audio, hence lower.
    private let threshold: Float
    /// Seconds kept before/after the active span (plosives, trailing
    /// consonants).
    private let padding: Double
    private let fallback: EnergyVAD

    public init(
        modelURL: URL,
        threshold: Float = 0.3,
        padding: Double = 0.2,
        fallback: EnergyVAD = EnergyVAD()
    ) throws {
        let configuration = MLModelConfiguration()
        // The model is under 1 MB; CPU inference is microseconds per chunk
        // and skips ANE dispatch latency.
        configuration.computeUnits = .cpuOnly
        self.model = try MLModel(contentsOf: modelURL, configuration: configuration)
        self.threshold = threshold
        self.padding = padding
        self.fallback = fallback
    }

    /// Chunks quieter than this RMS are silence, no model needed. The model
    /// misbehaves on degenerate input — all-zero samples score ~0.76 speech
    /// probability — and real mic capture never sits this far below the
    /// noise floor, so the gate only ever catches true digital silence
    /// (including our own zero-padding of the final partial chunk).
    private static let silenceRMSGate: Float = 0.0005

    private func predictions(for samples: [Float]) throws -> [Float] {
        let scratch = try MLMultiArray(
            shape: [1, NSNumber(value: Self.chunkLength)],
            dataType: .float32
        )
        let pointer = scratch.dataPointer.assumingMemoryBound(to: Float.self)
        var probabilities: [Float] = []
        probabilities.reserveCapacity(samples.count / Self.chunkLength + 1)

        var offset = 0
        while offset < samples.count {
            let end = min(offset + Self.chunkLength, samples.count)
            let count = end - offset
            var energy: Float = 0
            samples.withUnsafeBufferPointer { source in
                let base = source.baseAddress! + offset
                pointer.update(from: base, count: count)
                for i in 0..<count { energy += base[i] * base[i] }
            }
            if (energy / Float(count)).squareRoot() < Self.silenceRMSGate {
                probabilities.append(0)
                offset = end
                continue
            }
            if count < Self.chunkLength {
                for i in count..<Self.chunkLength { pointer[i] = 0 }
            }
            let output = try model.prediction(
                from: MLDictionaryFeatureProvider(dictionary: ["audio_chunk": scratch])
            )
            guard let value = output.featureValue(for: "vad_probability")?.multiArrayValue else {
                throw SileroVADError.unexpectedModelOutput
            }
            probabilities.append(Float(truncating: value[0]))
            offset = end
        }
        return probabilities
    }
}

extension SileroVAD: VoiceActivityDetecting {
    public func trimSilence(_ samples: [Float], sampleRate: Double) -> [Float] {
        // The model is trained for 16 kHz only; anything else (shouldn't
        // happen — the recorder resamples) goes to the energy heuristic.
        guard sampleRate == Self.requiredSampleRate else {
            return fallback.trimSilence(samples, sampleRate: sampleRate)
        }
        guard !samples.isEmpty else { return [] }
        do {
            let probabilities = try predictions(for: samples)
            guard
                let first = probabilities.firstIndex(where: { $0 >= threshold }),
                let last = probabilities.lastIndex(where: { $0 >= threshold })
            else { return [] }
            let pad = Int(padding * sampleRate)
            let start = max(0, first * Self.chunkLength - pad)
            let end = min(samples.count, (last + 1) * Self.chunkLength + pad)
            return Array(samples[start..<end])
        } catch {
            NSLog("fabulous: Silero VAD prediction failed (\(error)); energy fallback")
            return fallback.trimSilence(samples, sampleRate: sampleRate)
        }
    }
}

public enum SileroVADError: Error, Sendable {
    case unexpectedModelOutput
}
