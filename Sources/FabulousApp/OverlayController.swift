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
    /// Transcription decode progress, 0…1.
    var progress: Double = 0
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
        model.progress = 0
        show()
    }

    func updateProgress(_ fraction: Double) {
        // Monotonic — a progress readout that moves backwards reads as broken.
        model.progress = max(model.progress, min(1, fraction))
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

/// Shared palette: near-monochrome ice — silver-white with the faintest
/// cold cast, on black glass. The color comes from light, not from hue.
private enum OverlayStyle {
    static let ice = Color(red: 0.88, green: 0.93, blue: 1.0)
    static let iceDim = Color(red: 0.62, green: 0.68, blue: 0.78)
}

private struct OverlayView: View {
    let model: OverlayModel

    var body: some View {
        ZStack {
            switch model.phase {
            case .recording:
                CapsuleChrome {
                    PixelMatrixWave(level: model.level)
                        .frame(width: 88, height: 26)
                }
            case .transcribing:
                CapsuleChrome {
                    HStack(spacing: 9) {
                        PixelSpinner()
                            .frame(width: 20, height: 20)
                        Text(percentText)
                            .font(.caption.weight(.medium).monospacedDigit())
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

    /// Honest about where decoding stands. Shows "…" until the first real
    /// progress report arrives rather than pretending with a fake number.
    private var percentText: String {
        model.progress > 0
            ? "\(Int((model.progress * 100).rounded()))%"
            : "…"
    }
}

/// The capsule shell: near-black glass, a whisper of a rim line, and a
/// plain soft shadow. The motion lives in the content, not the frame.
private struct CapsuleChrome<Content: View>: View {
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
                            .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.4), radius: 9, y: 3)
    }
}

/// Voice as a retro LED matrix: a grid of discrete square pixels where each
/// column fills upward from the center in quantized steps. Two travelling
/// waves drive the column heights, scaled by the live input level — so it
/// surges when you speak — and the topmost lit pixel of each column burns
/// brightest, like an equalizer's peak dot.
private struct PixelMatrixWave: View {
    var level: Float

    private static let columns = 15
    private static let rows = 7 // odd: symmetric around the center row

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let cols = Self.columns
                let rows = Self.rows
                let cell: CGFloat = 2.6
                let gapX = (size.width - CGFloat(cols) * cell) / CGFloat(cols - 1)
                let gapY = (size.height - CGFloat(rows) * cell) / CGFloat(rows - 1)
                let midRow = rows / 2
                let drive = CGFloat(min(1, max(0, level)))
                let idle: CGFloat = 0.1

                for col in 0..<cols {
                    let phase = Double(col) * 0.6
                    let wave = 0.6 * sin(t * 6.0 + phase)
                        + 0.4 * sin(t * 9.5 - phase * 1.3)
                    let center = abs(CGFloat(col) - CGFloat(cols - 1) / 2)
                        / (CGFloat(cols - 1) / 2)
                    let envelope = 1.0 - center * center * 0.75
                    let amplitude = (idle + drive * 0.9) * envelope
                        * CGFloat(0.5 + 0.5 * abs(wave))
                    // Quantize: how many pixels above/below center light up.
                    let lit = Int((amplitude * CGFloat(midRow)).rounded())

                    for row in 0..<rows {
                        let distance = abs(row - midRow)
                        let x = CGFloat(col) * (cell + gapX)
                        let y = CGFloat(row) * (cell + gapY)
                        let rect = CGRect(x: x, y: y, width: cell, height: cell)

                        let opacity: CGFloat = if distance == 0 {
                            0.95 // center row always alive
                        } else if distance < lit {
                            0.55
                        } else if distance == lit {
                            1.0 // the peak pixel burns brightest
                        } else {
                            0.1 // unlit grid stays faintly visible
                        }
                        context.fill(
                            Path(rect),
                            with: .color(OverlayStyle.ice.opacity(opacity))
                        )
                    }
                }
            }
        }
    }
}

/// A pixel-ring spinner: twelve square pixels in a circle, lit as a comet
/// that steps around the ring in discrete ticks — deliberately quantized,
/// matching the recording matrix.
private struct PixelSpinner: View {
    private static let pixels = 12

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let count = Self.pixels
                let cell: CGFloat = 2.8
                let radius = min(size.width, size.height) / 2 - cell
                let mid = CGPoint(x: size.width / 2, y: size.height / 2)
                // Discrete ticks, not smooth rotation — pixels don't glide.
                let head = Int(t * 12) % count

                for index in 0..<count {
                    let angle = Double(index) / Double(count) * 2 * .pi - .pi / 2
                    let x = mid.x + cos(angle) * radius - cell / 2
                    let y = mid.y + sin(angle) * radius - cell / 2
                    // Comet tail: brightness falls off behind the head.
                    let lag = (head - index + count) % count
                    let opacity = max(0.08, 1.0 - Double(lag) * 0.16)
                    context.fill(
                        Path(CGRect(x: x, y: y, width: cell, height: cell)),
                        with: .color(OverlayStyle.ice.opacity(opacity))
                    )
                }
            }
        }
    }
}
