import Foundation

/// Whether an empty/short finish should show the "mic lost" notice. Gated
/// solely on capture health: a healthy accidental tap or scratch-that stays
/// silent (preserves the branch's deliberately-silent finish paths); only a
/// failed capture surfaces the notice.
public enum CaptureFailureNotice {
    public static func shouldNotify(captureHealthy: Bool) -> Bool {
        !captureHealthy
    }
}
