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

/// The floating recording pill: a borderless, non-activating panel at the
/// bottom-center of the screen the user is working on. It never takes focus
/// (that would break dictation — the target app must stay frontmost) and
/// ignores the mouse entirely.
@MainActor
final class OverlayController {
    private let model = OverlayModel()
    private var panel: NSPanel?

    private static let pillSize = NSSize(width: 320, height: 52)
    private static let bottomMargin: CGFloat = 96

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
        // Light exponential smoothing so the meter breathes instead of
        // flickering per buffer.
        model.level = model.level * 0.6 + min(1, level * 4) * 0.4
    }

    /// Shows a transient notice in the pill, then hides. Used by the
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
            x: frame.midX - Self.pillSize.width / 2,
            y: frame.minY + Self.bottomMargin
        ))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.pillSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
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
        HStack(spacing: 10) {
            switch model.phase {
            case .recording:
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                LevelMeter(level: model.level)
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Transcribing…")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
            case let .message(text):
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.yellow)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 18)
        .frame(width: 320, height: 52)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.black.opacity(0.82))
        )
    }
}

/// A row of bars whose heights follow the input level, with a fixed per-bar
/// profile so the middle reacts first — reads as a voice meter without
/// pretending to be a spectrum.
private struct LevelMeter: View {
    var level: Float

    private static let profile: [Float] = [
        0.35, 0.55, 0.8, 1.0, 0.85, 1.0, 0.7, 0.9, 0.6, 0.45,
    ]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<Self.profile.count, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 4, height: barHeight(index))
            }
        }
        .animation(.linear(duration: 0.05), value: level)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let scaled = CGFloat(min(1, level) * Self.profile[index])
        return 4 + scaled * 24
    }
}
