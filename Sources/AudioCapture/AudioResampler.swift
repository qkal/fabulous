import AVFoundation

/// Converts capture-format buffers (whatever the input device produces) to
/// the ASR format via AVAudioConverter. Streaming-friendly: the converter
/// keeps its filter state between calls, so feeding successive tap buffers
/// produces continuous output.
///
/// Not thread-safe. `AudioRecorder` guarantees single-threaded access from
/// the audio tap callback.
public final class AudioResampler {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let ratio: Double

    public init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.converter = converter
        self.outputFormat = outputFormat
        self.ratio = outputFormat.sampleRate / inputFormat.sampleRate
    }

    /// Converts one buffer, returning mono Float32 samples in the output
    /// sample rate. Returns nil on converter error.
    public func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat, frameCapacity: capacity
        ) else { return nil }

        // The input block is @Sendable in the SDK, but AVAudioConverter
        // invokes it synchronously inside convert() on this thread — the
        // captured state never actually crosses a concurrency boundary.
        nonisolated(unsafe) var pending: AVAudioPCMBuffer? = buffer
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard let next = pending else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            pending = nil
            inputStatus.pointee = .haveData
            return next
        }

        guard status != .error, conversionError == nil,
              let channelData = output.floatChannelData
        else { return nil }

        return Array(UnsafeBufferPointer(
            start: channelData[0], count: Int(output.frameLength)
        ))
    }
}
