import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class OverlayModel {
    enum Phase: Equatable {
        case recording
        case transcribing
        /// Transient notice, e.g. "Focus changed — copied to clipboard".
        case message(String)
    }

    var phase: Phase = .recording
    /// Smoothed input level, 0…1.
    var level: Float = 0
}

/// The floating dictation indicator: a borderless, non-activating panel at
/// the bottom-center of the screen the user is working on. It never takes
/// focus (that would break dictation — the target app must stay frontmost)
/// and ignores the mouse entirely.
///
/// The panel is a fixed transparent stage; the visible capsule is drawn in
/// SwiftUI and sized per phase, so the compact waveform and the wider
/// message notice share one window.
@MainActor
final class OverlayController {
    private let model = OverlayModel()
    private var panel: NSPanel?

    private static let stageSize = NSSize(width: 360, height: 72)
    private static let bottomMargin: CGFloat = 84

    func showRecording() {
        model.phase = .recording
        model.level = 0
        show()
    }

    func showTranscribing() {
        model.phase = .transcribing
        show()
    }

    func updateLevel(_ level: Float) {
        // Light exponential smoothing so the wave breathes instead of
        // flickering per buffer.
        model.level = model.level * 0.6 + min(1, level * 4) * 0.4
    }

    /// Shows a transient notice in the capsule, then hides. Used by the
    /// injection safety net so failures are visible without being modal.
    func showMessage(_ text: String, hideAfter seconds: Double = 3) {
        model.phase = .message(text)
        show()
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            if case .message = model.phase {
                hide()
            }
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private var messageTask: Task<Void, Never>?

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel, on: activeScreen())
        panel.orderFrontRegardless()
    }

    /// The screen the user is most plausibly looking at: the one with the
    /// mouse pointer. (The focused window's screen isn't knowable without
    /// more AX digging; this heuristic is what Apple's own dictation uses.)
    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func position(_ panel: NSPanel, on screen: NSScreen?) {
        guard let screen else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - Self.stageSize.width / 2,
            y: frame.minY + Self.bottomMargin
        ))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.stageSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Shadow is drawn in SwiftUI (a soft glow); the window shadow would
        // trace the full transparent stage rect and leave artifacts.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
        return panel
    }
}

// MARK: - Views

/// Shared palette: the Siri-ish cool gradient used by the wave, the glow,
/// and the capsule's rim light.
private enum OverlayStyle {
    static let gradient = LinearGradient(
        colors: [
            Color(red: 0.35, green: 0.62, blue: 1.0),
            Color(red: 0.62, green: 0.45, blue: 1.0),
            Color(red: 0.95, green: 0.40, blue: 0.78),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let glow = Color(red: 0.55, green: 0.5, blue: 1.0)
}

private struct OverlayView: View {
    let model: OverlayModel

    var body: some View {
        ZStack {
            switch model.phase {
            case .recording:
                CapsuleChrome {
                    SiriWave(level: model.level, energetic: true)
                        .frame(width: 96, height: 26)
                }
            case .transcribing:
                CapsuleChrome {
                    HStack(spacing: 8) {
                        SiriWave(level: 0.25, energetic: false)
                            .frame(width: 54, height: 18)
                        Text("Transcribing")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            case let .message(text):
                CapsuleChrome {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.yellow)
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: 300)
                }
            }
        }
        .frame(width: 360, height: 72)
        .animation(.easeOut(duration: 0.18), value: model.phase)
    }
}

/// The capsule shell: near-black glass, a faint gradient rim light, and a
/// soft colored glow instead of a hard window shadow.
private struct CapsuleChrome<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(.black.opacity(0.78))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(OverlayStyle.gradient.opacity(0.55), lineWidth: 1)
                    )
            )
            .shadow(color: OverlayStyle.glow.opacity(0.35), radius: 14, y: 2)
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }
}

/// A Siri-inspired waveform: a row of thin gradient bars whose heights ride
/// travelling sine waves, scaled by the live input level so the wave surges
/// when you speak and settles to a gentle idle breath when you pause.
private struct SiriWave: View {
    var level: Float
    /// Recording waves surge with voice; the transcribing wave just idles.
    var energetic: Bool

    private static let barCount = 17

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let barWidth: CGFloat = 2.5
                let gap = (size.width - CGFloat(Self.barCount) * barWidth)
                    / CGFloat(Self.barCount - 1)
                let midY = size.height / 2
                let drive = CGFloat(min(1, max(0, level)))
                // Idle breath keeps the wave alive between words.
                let idle: CGFloat = energetic ? 0.12 : 0.3

                for index in 0..<Self.barCount {
                    let x = CGFloat(index) * (barWidth + gap)
                    let phase = Double(index) * 0.55
                    // Two travelling waves at different speeds so the motion
                    // never reads as a loop.
                    let wave = 0.6 * sin(t * 6.0 + phase)
                        + 0.4 * sin(t * 9.5 - phase * 1.3)
                    // Center-weighted envelope: middle bars react hardest.
                    let center = abs(CGFloat(index) - CGFloat(Self.barCount - 1) / 2)
                        / (CGFloat(Self.barCount - 1) / 2)
                    let envelope = 1.0 - center * center * 0.75
                    let amplitude = (idle + drive * (energetic ? 0.88 : 0.2))
                        * envelope * CGFloat(0.5 + 0.5 * abs(wave))
                    let height = max(barWidth, amplitude * size.height)

                    let rect = CGRect(
                        x: x, y: midY - height / 2,
                        width: barWidth, height: height
                    )
                    let bar = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                    context.fill(
                        bar,
                        with: .linearGradient(
                            Gradient(colors: [
                                Color(red: 0.35, green: 0.62, blue: 1.0),
                                Color(red: 0.62, green: 0.45, blue: 1.0),
                                Color(red: 0.95, green: 0.40, blue: 0.78),
                            ]),
                            startPoint: CGPoint(x: 0, y: midY),
                            endPoint: CGPoint(x: size.width, y: midY)
                        )
                    )
                }
            }
        }
    }
}
