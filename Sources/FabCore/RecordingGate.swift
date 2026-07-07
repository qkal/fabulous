import Foundation

/// Pure push-to-talk / toggle lifecycle so the press/release race is testable.
///
/// Fixes two races: a fast PTT tap whose release lands while `recorder.start()`
/// is still awaiting (previously dropped, leaving the recorder running forever),
/// and a double toggle-press that fired `finishRecording` twice.
public struct RecordingGate: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case pushToTalk, toggle }
    public enum Phase: Equatable, Sendable { case idle, starting, recording, finishing }
    public enum Event: Equatable, Sendable { case press, release, startSucceeded, startFailed, finished }
    public enum Action: Equatable, Sendable {
        case none
        case beginStart      // kick recorder.start()
        case goLive          // became recording: overlay, level meter, streaming session
        case finish          // run finishRecording (stop + transcribe)
        case abortToIdle     // start failed → clean up to idle
    }

    public private(set) var phase: Phase = .idle
    private var stopRequested = false

    public init() {}

    public mutating func handle(_ event: Event, mode: Mode) -> Action {
        // `finished` always resets — covers normal finish and Esc-cancel.
        if event == .finished {
            phase = .idle
            stopRequested = false
            return .none
        }
        switch phase {
        case .idle:
            if event == .press {
                phase = .starting
                stopRequested = false
                return .beginStart
            }
            return .none

        case .starting:
            switch event {
            case .release:
                stopRequested = true          // PTT released before recording began
                return .none
            case .press where mode == .toggle:
                stopRequested = true          // toggled off before it started
                return .none
            case .startSucceeded:
                if stopRequested {
                    phase = .finishing        // finishRecording discards if too short
                    return .finish
                }
                phase = .recording
                return .goLive
            case .startFailed:
                phase = .idle
                stopRequested = false
                return .abortToIdle
            default:
                return .none                  // repeated PTT press, stray events
            }

        case .recording:
            switch event {
            case .release where mode == .pushToTalk, .press where mode == .toggle:
                phase = .finishing
                return .finish
            default:
                return .none
            }

        case .finishing:
            return .none                      // second press/release ignored → single finish
        }
    }
}
