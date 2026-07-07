import Foundation

/// When to trim silence relative to stopping the recorder.
///
/// With a live streaming session we stop *raw* (a trim pass at release would
/// re-charge exactly the latency streaming removes) and trim lazily only if we
/// fall back to batch. Without a session the recorder already VAD-trims at stop.
public enum StreamStopPolicy {
    public static func trimAtStop(hasSession: Bool) -> Bool { !hasSession }
    public static func needsLazyTrim(hasSession: Bool) -> Bool { hasSession }
}
