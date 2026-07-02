import AppKit

/// Subtle audio feedback so recording state is knowable without looking at
/// the pill. System sounds, played quietly; the settings toggle gates all of
/// them. Sound choice is a spec open question — revisit after a week of use.
@MainActor
enum SoundCues {
    static func recordingStarted() { play("Tink", volume: 0.3) }
    static func recordingStopped() { play("Pop", volume: 0.3) }
    static func recordingCancelled() { play("Bottle", volume: 0.25) }

    private static func play(_ name: String, volume: Float) {
        guard let sound = NSSound(named: name) else { return }
        sound.volume = volume
        sound.play()
    }
}
