import AVFoundation
import FabCore
import Foundation
import Speech

/// Apple's on-device ASR via the macOS 26 `SpeechAnalyzer` API.
///
/// Unlike WhisperKit, the model assets are owned by the OS: `load` reserves
/// the locale and asks `AssetInventory` to download whatever is missing, so
/// nothing shows up in our Models tab and nothing lives under our
/// Application Support directory. `SpeechAnalyzer.Options.modelRetention`
/// is set to `.processLifetime`, which is this backend's version of the
/// keep-warm policy (latency > memory, per the phase-3 spec).
@available(macOS 26.0, *)
public actor SpeechAnalyzerBackend: StreamingTranscriptionBackend {
    /// The locale the analyzer was prepared for; nil until `load` succeeds.
    private var loadedLocale: Locale?

    private static let analyzerOptions = SpeechAnalyzer.Options(
        priority: .userInitiated,
        modelRetention: .processLifetime
    )

    public init() {}

    /// The descriptor is accepted for protocol conformance but there is only
    /// one "model": the OS asset for the user's locale.
    public func load(model: ModelDescriptor) async throws {
        if loadedLocale != nil { return }
        guard SpeechTranscriber.isAvailable else {
            throw SpeechAnalyzerBackendError.transcriberUnavailable
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw SpeechAnalyzerBackendError.localeUnsupported(Locale.current.identifier)
        }

        let transcriber = Self.makeTranscriber(locale: locale)
        // Reservation can fail when the per-process locale cap is hit; the
        // installation request below still succeeds if the OS already holds
        // the assets (e.g. the system keyboard language), so don't bail yet.
        _ = try? await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        // Pay the one-time model preparation now, not on the first dictation.
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: Self.analyzerOptions)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        await analyzer.cancelAndFinishNow()

        loadedLocale = locale
    }

    /// `language` is ignored: SpeechTranscriber is locale-bound at load time
    /// (auto-detection isn't offered), and fabulous always passes nil today.
    public func transcribe(
        _ audio: FabCore.AudioBuffer,
        language: Language?,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript {
        guard let locale = loadedLocale else { throw TranscriptionError.modelNotLoaded }
        guard !audio.isEmpty else { return Transcript(text: "", audioDuration: 0) }

        // Modules are single-use: a fresh transcriber/analyzer per utterance,
        // with .processLifetime retention keeping the underlying model warm.
        let transcriber = Self.makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: Self.analyzerOptions)

        guard
            let source = Self.pcmBuffer(from: audio),
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber],
                considering: source.format
            ),
            let converted = Self.convert(source, to: format)
        else {
            throw SpeechAnalyzerBackendError.audioConversionFailed
        }

        // Subscribe before feeding audio so no result can slip past. The
        // task inherits this actor's executor and interleaves with the
        // awaited analysis below.
        let collector = Task {
            var pieces: [String] = []
            for try await result in transcriber.results where result.isFinal {
                let piece = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { pieces.append(piece) }
            }
            return pieces.joined(separator: " ")
        }

        let (inputSequence, builder) = AsyncStream<AnalyzerInput>.makeStream()
        builder.yield(AnalyzerInput(buffer: converted))
        builder.finish()
        do {
            let lastSampleTime = try await analyzer.analyzeSequence(inputSequence)
            if let lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }

        let text = try await collector.value
        return Transcript(text: text, audioDuration: audio.duration)
    }

    public func unload() {
        // The OS decides when to evict its models; forgetting the locale is
        // all the "unload" this backend has.
        loadedLocale = nil
    }

    public func startStreamingSession() async throws -> any StreamingSession {
        guard let locale = loadedLocale else { throw TranscriptionError.modelNotLoaded }
        return try await SpeechAnalyzerStreamingSession(
            locale: locale, options: Self.analyzerOptions
        )
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        // Final results only — batch transcription has no consumer for
        // volatile partials; the streaming session (below) opts into them.
        SpeechTranscriber(locale: locale, preset: .transcription)
    }

    // MARK: - Audio plumbing

    /// Wraps our 16 kHz mono Float32 samples in an AVAudioPCMBuffer.
    static func pcmBuffer(from audio: FabCore.AudioBuffer) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: audio.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(audio.samples.count)
            ),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        audio.samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: source.count)
        }
        buffer.frameLength = AVAudioFrameCount(audio.samples.count)
        return buffer
    }

    /// One-shot sample-rate/format conversion into what the analyzer wants.
    static func convert(
        _ buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            return nil
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        // The input block is @Sendable but AVAudioConverter drives it
        // synchronously inside `convert` on this thread; the buffer never
        // actually crosses an isolation boundary.
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let input = buffer
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil else { return nil }
        return output
    }
}

/// One live utterance against SpeechAnalyzer: input stream held open,
/// volatile results forwarded as partials, `finish()` = finalize wait.
@available(macOS 26.0, *)
actor SpeechAnalyzerStreamingSession: StreamingSession {
    nonisolated let partials: AsyncStream<String>
    private let partialsContinuation: AsyncStream<String>.Continuation

    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let analyzeTask: Task<CMTime?, Error>
    private let collector: Task<String, Error>

    /// Total samples fed, for the transcript's audioDuration.
    private var fedSampleCount = 0
    private let fedSampleRate: Double = AudioConstants.expectedSampleRate
    private var ended = false

    /// 16 kHz mono Float32 — what the capture pipeline produces.
    private enum AudioConstants {
        static let expectedSampleRate: Double = 16_000
    }

    init(locale: Locale, options: SpeechAnalyzer.Options) async throws {
        // Volatile results on: partials are the point of a live session.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        guard
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber]
            )
        else {
            throw SpeechAnalyzerBackendError.audioConversionFailed
        }
        analyzerFormat = format

        (partials, partialsContinuation) = AsyncStream.makeStream()

        // Finalized pieces accumulate; the volatile tail is replaced on
        // every non-final result. Each update emits the full string so far.
        let continuation = partialsContinuation
        collector = Task {
            var pieces: [String] = []
            var volatileTail = ""
            for try await result in transcriber.results {
                let piece = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if result.isFinal {
                    if !piece.isEmpty { pieces.append(piece) }
                    volatileTail = ""
                } else {
                    volatileTail = piece
                }
                let current = (pieces + (volatileTail.isEmpty ? [] : [volatileTail]))
                    .joined(separator: " ")
                continuation.yield(current)
            }
            return pieces.joined(separator: " ")
        }

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        input = inputBuilder
        let analyzerRef = analyzer
        analyzeTask = Task {
            try await analyzerRef.analyzeSequence(inputSequence)
        }
    }

    func feed(_ samples: [Float]) {
        guard !ended, !samples.isEmpty else { return }
        let chunk = FabCore.AudioBuffer(
            samples: samples, sampleRate: AudioConstants.expectedSampleRate
        )
        guard
            let source = SpeechAnalyzerBackend.pcmBuffer(from: chunk),
            let converted = SpeechAnalyzerBackend.convert(source, to: analyzerFormat)
        else {
            // A malformed chunk shouldn't kill the utterance; skip it and
            // let the batch fallback cover any resulting quality gap.
            return
        }
        fedSampleCount += samples.count
        input.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async throws -> Transcript {
        guard !ended else { throw SpeechAnalyzerBackendError.sessionAlreadyEnded }
        ended = true
        input.finish()
        do {
            let lastSampleTime = try await analyzeTask.value
            if let lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            partialsContinuation.finish()
            throw error
        }
        let text = try await collector.value
        partialsContinuation.finish()
        return Transcript(
            text: text,
            audioDuration: Double(fedSampleCount) / fedSampleRate
        )
    }

    func cancel() async {
        guard !ended else { return }
        ended = true
        input.finish()
        collector.cancel()
        await analyzer.cancelAndFinishNow()
        partialsContinuation.finish()
    }
}

public enum SpeechAnalyzerBackendError: Error, Sendable {
    /// SpeechTranscriber reports itself unavailable on this system.
    case transcriberUnavailable
    /// No SpeechTranscriber locale matches the user's locale.
    case localeUnsupported(String)
    case audioConversionFailed
    /// `finish()` was called on a session that already finished or cancelled.
    case sessionAlreadyEnded
}

extension SpeechAnalyzerBackendError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .transcriberUnavailable:
            "Apple Speech isn't available on this Mac."
        case .localeUnsupported(let identifier):
            "Apple Speech doesn't support the \(identifier) locale."
        case .audioConversionFailed:
            "Couldn't convert audio for Apple Speech."
        case .sessionAlreadyEnded:
            "The dictation session already ended."
        }
    }
}
