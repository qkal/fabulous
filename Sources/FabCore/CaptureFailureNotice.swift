import Foundation

/// Whether an empty/short finish should show the "mic lost" notice. Gated on
/// capture health so a healthy accidental tap or scratch-that stays silent
/// (preserves the branch's deliberately-silent finish paths).
public enum CaptureFailureNotice {
    public static func shouldNotify(captureHealthy: Bool, transcriptEmpty: Bool) -> Bool {
        !captureHealthy
    }
}
