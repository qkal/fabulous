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
    /// Live partial transcript while streaming (empty = hidden). Raw engine
    /// output — post-processing only runs on the final text.
    var partialText: String = ""
    /// Active theme, pushed by AppController (the overlay has no store
    /// binding). Set before the first show and on every theme change.
    var theme: Theme = .paper
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
        model.partialText = ""
        show()
    }

    func showTranscribing() {
        model.phase = .transcribing
        show()
    }

    func updateLevel(_ level: Float) {
        // Perceptual mapping: speech RMS lives around -45…-15 dB, so a linear
        // scale leaves the wave nearly still while talking. dB-normalize into
        // 0…1, then smooth with a fast attack (words hit instantly) and a
        // slow release (the wave settles instead of flickering).
        let db = 20 * log10(max(level, 0.000_01))
        let normalized = min(1, max(0, (db + 48) / 36))
        if normalized > model.level {
            model.level = model.level * 0.25 + normalized * 0.75
        } else {
            model.level = model.level * 0.85 + normalized * 0.15
        }
    }

    /// Streams the live partial transcript into the recording pill.
    func updatePartial(_ text: String) {
        guard model.phase == .recording else { return }
        model.partialText = text
    }

    /// Applies a theme; safe to call while the pill is visible.
    func applyTheme(_ theme: Theme) {
        model.theme = theme
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

private struct OverlayView: View {
    let model: OverlayModel

    var body: some View {
        ZStack {
            switch model.phase {
            case .recording:
                CapsuleChrome(energy: CGFloat(min(1, model.level))) {
                    VStack(spacing: 5) {
                        VoiceBars(level: model.level)
                            .frame(width: 64, height: 30)
                        if !model.partialText.isEmpty {
                            Text(model.partialText)
                                .font(.caption)
                                .foregroundStyle(model.theme.inkSecondary)
                                .lineLimit(1)
                                .truncationMode(.head)   // tail of speech wins
                                .frame(maxWidth: 280)
                                .transition(.opacity)
                        }
                    }
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
                            .foregroundStyle(model.theme.accent)
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(model.theme.ink.opacity(0.9))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: 300)
                }
            }
        }
        .scaleEffect(model.visible ? 1 : 0.6, anchor: .bottom)
        .offset(y: model.visible ? 0 : 16)
        .opacity(model.visible ? 1 : 0)
        .blur(radius: model.visible ? 0 : 3)
        .animation(.spring(response: 0.34, dampingFraction: 0.7), value: model.visible)
        .frame(width: 360, height: 72)
        .animation(.easeOut(duration: 0.18), value: model.phase)
        .environment(\.theme, model.theme)
        .tint(model.theme.accent)
    }

}

/// The capsule shell — frosted paper or the original black glass, chosen by
/// the theme. `energy` (the live voice level) swells the capsule a few
/// percent and wakes the rim/halo so the object feels alive while you speak.
private struct CapsuleChrome<Content: View>: View {
    var energy: CGFloat = 0
    @ViewBuilder let content: Content

    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch theme.pillStyle {
            case .frosted:
                padded
                    .background {
                        ZStack {
                            Capsule(style: .continuous)
                                .fill(.ultraThinMaterial)
                            // Warm paper tint over the material so the frost
                            // reads paper, not gray.
                            Capsule(style: .continuous)
                                .fill(theme.paper.opacity(0.42))
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    theme.ink.opacity(0.14 + 0.25 * energy),
                                    lineWidth: 1
                                )
                        }
                    }
                    .scaleEffect(1 + energy * 0.045)
                    .shadow(color: theme.accent.opacity(0.28 * energy), radius: 14, y: 0)
                    .shadow(color: .black.opacity(0.10 + 0.10 * energy), radius: 14, y: 4)
            case .glass:
                padded
                    .background(
                        Capsule(style: .continuous)
                            .fill(.black.opacity(0.8))
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(
                                        .white.opacity(0.14 + 0.3 * energy),
                                        lineWidth: 1
                                    )
                            )
                    )
                    .scaleEffect(1 + energy * 0.045)
                    .shadow(color: theme.pillGlow.opacity(0.3 * energy), radius: 12, y: 0)
                    .shadow(color: .black.opacity(0.4), radius: 9, y: 3)
            }
        }
        .animation(.easeOut(duration: 0.12), value: energy)
    }

    private var padded: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
    }
}

/// The voice meter: seven chunky rounded bars riding two travelling sine
/// waves, driven by the dB-normalized input level — near-dots in silence,
/// surging tall the moment you speak. Loud bars flush from ink to the
/// accent color, so loudness reads as both height and light.
private struct VoiceBars: View {
    var level: Float

    @Environment(\.theme) private var theme

    private static let barCount = 7

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let barWidth: CGFloat = 5
                let gap = (size.width - CGFloat(Self.barCount) * barWidth)
                    / CGFloat(Self.barCount - 1)
                let midY = size.height / 2
                let drive = CGFloat(min(1, max(0, level)))
                // Idle breath keeps the meter alive between words.
                let idle: CGFloat = 0.14
                let surge: CGFloat = 0.86

                for index in 0..<Self.barCount {
                    let x = CGFloat(index) * (barWidth + gap)
                    let phase = Double(index) * 0.9
                    // Two travelling waves at different speeds so the motion
                    // never reads as a loop; voice nudges the tempo up.
                    let speed = 5.0 + Double(drive) * 3.0
                    let wave = 0.6 * sin(t * speed + phase)
                        + 0.4 * sin(t * (speed * 1.6) - phase * 1.3)
                    // Center-weighted envelope: middle bars react hardest.
                    let center = abs(CGFloat(index) - CGFloat(Self.barCount - 1) / 2)
                        / (CGFloat(Self.barCount - 1) / 2)
                    let envelope = 1.0 - center * center * 0.55
                    let amplitude = (idle + drive * surge)
                        * envelope * CGFloat(0.55 + 0.45 * abs(wave))
                    let height = max(barWidth, amplitude * size.height)

                    let rect = CGRect(
                        x: x, y: midY - height / 2,
                        width: barWidth, height: height
                    )
                    let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                    let heat = min(1, amplitude)
                    context.fill(
                        path,
                        with: .color(theme.ink.opacity(0.45 + 0.55 * heat))
                    )
                    // Accent bleeds in with loudness — silent bars stay ink.
                    context.fill(
                        path,
                        with: .color(theme.accent.opacity(Double(drive * heat) * 0.85))
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
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let angle = Angle(degrees: (t * 300).truncatingRemainder(dividingBy: 360))

            ZStack {
                // The faint full track grounds the motion.
                Circle()
                    .stroke(theme.ink.opacity(0.18), lineWidth: 2.5)
                // The comet: a gradient tail ending in the blue accent head.
                Circle()
                    .trim(from: 0.08, to: 0.42)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                theme.accent.opacity(0),
                                theme.accent,
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
