import Foundation

/// Per-stage timing of one dictation, measured from hotkey release to text
/// delivered. This is the evidence behind the < 1.5 s latency budget — and
/// behind any future decision to build streaming or a faster backend.
public struct DictationMetrics: Sendable, Equatable {
    /// Length of the (trimmed) audio that was transcribed.
    public var audioDuration: TimeInterval
    /// Stopping the engine, draining the tap, VAD trimming.
    public var stopAndTrim: Duration
    public var transcription: Duration
    public var postProcessing: Duration
    /// Injection, or the clipboard fallback when injection was refused.
    public var delivery: Duration
    /// Hotkey release → text delivered.
    public var total: Duration

    public init(
        audioDuration: TimeInterval,
        stopAndTrim: Duration,
        transcription: Duration,
        postProcessing: Duration,
        delivery: Duration,
        total: Duration
    ) {
        self.audioDuration = audioDuration
        self.stopAndTrim = stopAndTrim
        self.transcription = transcription
        self.postProcessing = postProcessing
        self.delivery = delivery
        self.total = total
    }

    /// Compact one-liner for the menu bar, leading with what the user feels.
    /// e.g. "Last: 1.28 s · ASR 1.02 s · 10.4 s audio"
    public var menuSummary: String {
        "Last: \(Self.seconds(total)) · ASR \(Self.seconds(transcription))"
            + " · \(String(format: "%.1f", audioDuration)) s audio"
    }

    /// Full breakdown for the log.
    public var logLine: String {
        "dictation metrics: total=\(Self.seconds(total))"
            + " stop+vad=\(Self.seconds(stopAndTrim))"
            + " asr=\(Self.seconds(transcription))"
            + " post=\(Self.seconds(postProcessing))"
            + " delivery=\(Self.seconds(delivery))"
            + " audio=\(String(format: "%.2f", audioDuration))s"
    }

    /// True when the felt latency blew the budget (show a hint, not a party).
    public func exceedsBudget(_ budget: TimeInterval = 1.5) -> Bool {
        total > .seconds(budget)
    }

    /// Duration → fractional milliseconds, for persistence.
    public static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }

    static func seconds(_ duration: Duration) -> String {
        let secs = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2f s", secs)
    }
}
