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
    /// Drives the pop-in/out animation; the panel outlives the transition.
    var visible: Bool = false
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

    /// Animated dismissal: the capsule springs out first, then the panel
    /// is ordered out once the transition has played.
    func hide() {
        model.visible = false
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private var messageTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    private func show() {
        hideTask?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel, on: activeScreen())
        panel.orderFrontRegardless()
        if !model.visible {
            // Flip visibility a tick after the first layout so SwiftUI
            // animates the pop-in instead of rendering the final state.
            Task { @MainActor [model] in model.visible = true }
        }
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

/// Shared palette: near-monochrome ice — silver-white with the faintest
/// cold cast, on black glass. The color comes from light, not from hue.
private enum OverlayStyle {
    static let ice = Color(red: 0.88, green: 0.93, blue: 1.0)
}

private struct OverlayView: View {
    let model: OverlayModel

    var body: some View {
        ZStack {
            switch model.phase {
            case .recording:
                CapsuleChrome(energy: CGFloat(min(1, model.level))) {
                    SiriWave(level: model.level, energetic: true)
                        .frame(width: 96, height: 26)
                }
            case .transcribing:
                CapsuleChrome {
                    CometSpinner()
                        .frame(width: 22, height: 22)
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
        // Pop-in/out: rises from below with a spring, blurring away on exit.
        .scaleEffect(model.visible ? 1 : 0.6, anchor: .bottom)
        .offset(y: model.visible ? 0 : 16)
        .opacity(model.visible ? 1 : 0)
        .blur(radius: model.visible ? 0 : 3)
        .animation(.spring(response: 0.34, dampingFraction: 0.7), value: model.visible)
        .frame(width: 360, height: 72)
        .animation(.easeOut(duration: 0.18), value: model.phase)
    }

}

/// The capsule shell: near-black glass with a whisper of a rim line — and
/// it breathes. `energy` (the live voice level) swells the capsule a few
/// percent, brightens the rim, and wakes a soft halo, so the whole object
/// feels alive while you speak without a single extra ornament.
private struct CapsuleChrome<Content: View>: View {
    var energy: CGFloat = 0
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(.black.opacity(0.8))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(.white.opacity(0.14 + 0.3 * energy), lineWidth: 1)
                    )
            )
            .scaleEffect(1 + energy * 0.045)
            .shadow(color: OverlayStyle.ice.opacity(0.3 * energy), radius: 12, y: 0)
            .shadow(color: .black.opacity(0.4), radius: 9, y: 3)
            .animation(.easeOut(duration: 0.12), value: energy)
    }
}

/// The voice wave: a row of thin rounded bars riding two travelling sine
/// waves, scaled by the live input level — surging as you speak, settling
/// to a gentle idle breath in pauses. Monochrome: taller bars burn
/// brighter, so loudness reads as light.
private struct SiriWave: View {
    var level: Float
    /// Recording waves surge with voice; a calm wave just idles.
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
                let surge: CGFloat = energetic ? 0.88 : 0.2

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
                    let amplitude = (idle + drive * surge)
                        * envelope * CGFloat(0.5 + 0.5 * abs(wave))
                    let height = max(barWidth, amplitude * size.height)

                    let rect = CGRect(
                        x: x, y: midY - height / 2,
                        width: barWidth, height: height
                    )
                    let heat = amplitude / max(idle + surge, 0.01)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(OverlayStyle.ice.opacity(0.45 + 0.55 * min(1, heat)))
                    )
                }
            }
        }
    }
}

/// The transcribing spinner: a bright arc with a long fading tail, sweeping
/// smoothly around a faint track. One element, no text — the classic shape,
/// drawn with the overlay's own light.
private struct CometSpinner: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let angle = Angle(degrees: (t * 300).truncatingRemainder(dividingBy: 360))

            ZStack {
                // The faint full track grounds the motion.
                Circle()
                    .stroke(OverlayStyle.ice.opacity(0.15), lineWidth: 2.5)
                // The comet: a gradient tail ending in a bright head.
                Circle()
                    .trim(from: 0.08, to: 0.42)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                OverlayStyle.ice.opacity(0),
                                OverlayStyle.ice,
                            ]),
                            center: .center,
                            startAngle: .degrees(0.08 * 360),
                            endAngle: .degrees(0.42 * 360)
                        ),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(angle)
            }
        }
    }
}
