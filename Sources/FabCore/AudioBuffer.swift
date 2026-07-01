import Foundation

/// A chunk of mono PCM audio, ready for the ASR engine.
///
/// By convention everything downstream of `AudioCapture` operates on
/// 16 kHz mono Float32 samples in the range [-1, 1].
public struct AudioBuffer: Sendable, Equatable {
    public var samples: [Float]
    public var sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }

    public var isEmpty: Bool { samples.isEmpty }

    /// Overwrites the sample memory before releasing it. Audio never touches
    /// disk; this keeps it from lingering in reusable heap pages either.
    public mutating func zero() {
        for i in samples.indices { samples[i] = 0 }
        samples.removeAll(keepingCapacity: false)
    }
}
