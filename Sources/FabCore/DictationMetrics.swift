import Foundation

/// What the LLM cleanup stage did to one dictation. Persisted by raw value —
/// case names are part of the on-disk schema.
public enum LLMCleanupOutcome: String, Sendable, Codable, Equatable, CaseIterable {
    /// Cleanup disabled or unavailable; the stage never ran.
    case off
    /// The model ran and returned the transcript unmodified.
    case unchanged
    /// The model ran and altered the transcript.
    case changed
    /// The stage failed (throw, timeout, rejected empty output) and the raw
    /// transcript was used — the never-lose-text fallback.
    case fellBack
    /// The model returned output that invented content (failed the
    /// CleanupOutputGate novelty check) and the raw transcript was used —
    /// the never-invent-text fallback.
    case rejected
}

/// How one dictation's text reached the target app. Persisted by raw value —
/// case names are part of the on-disk schema. Decoupled from TextInjector's
/// InjectionStrategy on purpose: this is "how the text got delivered", which
/// includes the clipboard safety net that is not an injection strategy. The
/// first three raw values intentionally match InjectionStrategy's.
public enum DeliveryMethod: String, Sendable, Codable, Equatable, CaseIterable {
    case axInsert
    case paste
    case keystrokes
    /// Clipboard fallback, any reason: focus change, secure input,
    /// accessibility revoked, or all strategies failed.
    case safetyNet
}

/// Per-stage timing of one dictation, measured from hotkey release to text
/// delivered. This is the evidence behind the < 1.5 s latency budget — and
/// behind any future decision to build streaming or a faster backend.
public struct DictationMetrics: Sendable, Equatable {
    /// Length of the (trimmed) audio that was transcribed.
    public var audioDuration: TimeInterval
    /// Stopping the engine, draining the tap, VAD trimming.
    public var stopAndTrim: Duration
    public var transcription: Duration
    /// Wall time of the LLM cleanup stage; .zero when the stage was off.
    public var llmCleanup: Duration
    /// What the LLM cleanup stage did (off / unchanged / changed / fellBack / rejected).
    public var llmOutcome: LLMCleanupOutcome
    public var postProcessing: Duration
    /// Injection, or the clipboard fallback when injection was refused.
    public var delivery: Duration
    /// Hotkey release → text delivered.
    public var total: Duration
    /// True when the final text came from the streaming session (`transcription`
    /// ≈ the finalize wait). False for batch finals — including Parakeet hybrid
    /// dictations, where audio streams live for overlay partials but the
    /// inserted text is the batch decode.
    public var streamed: Bool
    /// How the text reached the target app. Defaults to the conservative
    /// safety-net label; the production caller always passes the real value.
    public var deliveryMethod: DeliveryMethod

    public init(
        audioDuration: TimeInterval,
        stopAndTrim: Duration,
        transcription: Duration,
        llmCleanup: Duration = .zero,
        llmOutcome: LLMCleanupOutcome = .off,
        postProcessing: Duration,
        delivery: Duration,
        total: Duration,
        streamed: Bool = false,
        deliveryMethod: DeliveryMethod = .safetyNet
    ) {
        self.audioDuration = audioDuration
        self.stopAndTrim = stopAndTrim
        self.transcription = transcription
        self.llmCleanup = llmCleanup
        self.llmOutcome = llmOutcome
        self.postProcessing = postProcessing
        self.delivery = delivery
        self.total = total
        self.streamed = streamed
        self.deliveryMethod = deliveryMethod
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
            + (llmOutcome == .off
                ? ""
                : " llm=\(Self.seconds(llmCleanup)) (\(llmOutcome.rawValue))")
            + " post=\(Self.seconds(postProcessing))"
            + " delivery=\(Self.seconds(delivery))"
            + " audio=\(String(format: "%.2f", audioDuration))s"
            + (streamed ? " streamed" : "")
            + " via=\(deliveryMethod.rawValue)"
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
