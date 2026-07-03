import AVFoundation
import Foundation

/// Receives buffers on the AVAudioEngine tap thread, resamples them to the
/// target format, and accumulates the result until `drain()` is called.
///
/// Safety invariant behind `@unchecked Sendable`: `process(_:)` is only ever
/// called from the engine's render tap, which delivers buffers serially, and
/// the sample store is guarded by a lock so `drain()`/`level` can be called
/// from any thread.
final class TapProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    /// Index of the first sample not yet returned by `drainNew()`.
    private var newCursor = 0
    private var latestRMS: Float = 0

    // Tap-thread-only state (no lock needed).
    private var resampler: AudioResampler?
    private var inputFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat

    init(targetSampleRate: Double) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            preconditionFailure("16 kHz mono Float32 is always constructible")
        }
        targetFormat = format
    }

    /// Called on the audio tap thread for every captured buffer.
    func process(_ buffer: AVAudioPCMBuffer) {
        // Device hot-swap changes the tap format mid-session; rebuild the
        // converter when that happens.
        if resampler == nil || inputFormat != buffer.format {
            resampler = AudioResampler(from: buffer.format, to: targetFormat)
            inputFormat = buffer.format
        }
        guard let converted = resampler?.convert(buffer), !converted.isEmpty else { return }

        var sum: Float = 0
        for sample in converted {
            sum += sample * sample
        }
        let rms = (sum / Float(converted.count)).squareRoot()

        lock.lock()
        samples.append(contentsOf: converted)
        latestRMS = rms
        lock.unlock()
    }

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

    /// RMS level of the most recent buffer, for the future level meter UI.
    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return latestRMS
    }
}
