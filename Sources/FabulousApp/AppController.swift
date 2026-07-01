import AppKit
import AudioCapture
import FabCore
import HotkeyEngine
import SwiftUI
import TextInjector
import TranscriptionEngine

/// Owns the dictation state machine and wires the modules together:
/// hotkey press → record → (release) → transcribe → post-process → inject.
@MainActor
final class AppController {
    enum State: Equatable {
        case needsPermissions
        case loadingModel
        case idle
        case recording
        case transcribing
        case failed(String)
    }

    private(set) var state: State = .needsPermissions {
        didSet { statusItem.update(for: state, hotkeyName: hotkeySpec.modifier.displayName) }
    }

    private let recorder = AudioRecorder()
    private let backend = WhisperKitBackend()
    private let injector = TextInjector()
    private let hotkey = HotkeyMonitor()
    private let statusItem = StatusItemController()
    // Passthrough today; the replacement dictionary and (v1.5) LLM cleanup
    // slot in here once they grow settings UI.
    private let postProcessor: any TextPostProcessor = PassthroughPostProcessor()

    private let hotkeySpec = HotkeySpec.default
    private var onboardingWindow: NSWindow?
    private(set) var lastTranscript: String?

    /// Recordings shorter than this are almost certainly an accidental tap.
    private let minimumUtteranceDuration: TimeInterval = 0.25

    func start() {
        statusItem.install(
            onShowSetup: { [weak self] in self?.showOnboarding() },
            onCopyLastTranscript: { [weak self] in self?.copyLastTranscript() }
        )
        hotkey.onPressBegan = { [weak self] in self?.hotkeyPressed() }
        hotkey.onPressEnded = { [weak self] in self?.hotkeyReleased() }

        if Permissions.allGranted {
            activateDictation()
        } else {
            state = .needsPermissions
            showOnboarding()
        }
    }

    /// Called once permissions are in place (at launch or from onboarding).
    private func activateDictation() {
        hotkey.start(spec: hotkeySpec)
        NSLog("fabulous: hotkey backend = \(hotkey.backend.rawValue)")
        state = .loadingModel
        Task {
            do {
                try await backend.load(model: .whisperBase)
                state = .idle
            } catch {
                state = .failed("Model load failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Push-to-talk state machine

    private func hotkeyPressed() {
        switch (hotkeySpec.mode, state) {
        case (.pushToTalk, .idle):
            Task { await beginRecording() }
        case (.toggle, .idle):
            Task { await beginRecording() }
        case (.toggle, .recording):
            Task { await finishRecording() }
        default:
            break
        }
    }

    private func hotkeyReleased() {
        guard hotkeySpec.mode == .pushToTalk, state == .recording else { return }
        Task { await finishRecording() }
    }

    private func beginRecording() async {
        guard Permissions.microphoneGranted else {
            showOnboarding()
            return
        }
        do {
            try await recorder.start()
            state = .recording
        } catch {
            await flashFailure("Couldn't start recording: \(error)")
        }
    }

    private func finishRecording() async {
        var audio = await recorder.stop()
        defer { audio.zero() }

        guard audio.duration >= minimumUtteranceDuration else {
            state = .idle
            return
        }
        state = .transcribing
        do {
            let transcript = try await backend.transcribe(audio, language: nil)
            let text = try await postProcessor.process(transcript.text)
            guard !text.isEmpty else {
                state = .idle
                return
            }
            lastTranscript = text
            statusItem.setLastTranscriptAvailable(true)
            try await injector.inject(text)
            state = .idle
        } catch let InjectionError.refused(reason) {
            let message = switch reason {
            case .secureInputActive: "A password field has focus — not typing there."
            case .accessibilityNotGranted: "Accessibility permission was revoked."
            }
            await flashFailure(message)
        } catch {
            await flashFailure("Transcription failed: \(error)")
        }
    }

    /// Shows an error state on the menu bar icon briefly, then returns to
    /// idle so the hotkey keeps working.
    private func flashFailure(_ message: String) async {
        NSLog("fabulous: \(message)")
        state = .failed(message)
        try? await Task.sleep(for: .seconds(4))
        if case .failed = state {
            state = .idle
        }
    }

    private func copyLastTranscript() {
        guard let lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(hotkeyName: hotkeySpec.modifier.displayName) { [weak self] in
            guard let self else { return }
            onboardingWindow?.close()
            if case .needsPermissions = state {
                activateDictation()
            }
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "fabulous"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
