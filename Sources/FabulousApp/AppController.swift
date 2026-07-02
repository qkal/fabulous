import AppKit
import AudioCapture
import FabCore
import HistoryStore
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
        /// Model download/load in flight; progress 0…1 when it's a download.
        case loadingModel(Double?)
        case idle
        case recording
        case transcribing
        case failed(String)
    }

    private(set) var state: State = .needsPermissions {
        didSet { statusItem.update(for: state, hotkeyName: settings.hotkeySpec.displayName) }
    }

    // Engines
    private let recorder = AudioRecorder()
    private let backend = WhisperKitBackend()
    private let injector = TextInjector()
    private let hotkey = HotkeyMonitor()
    private let modelManager = ModelManager()
    // Rebuilt from the settings' replacement entries; the (v1.5) LLM cleanup
    // pass slots in here as another pipeline stage.
    private var postProcessor: any TextPostProcessor = PassthroughPostProcessor()

    // App state & UI
    private let settings = SettingsStore()
    private let modelList = ModelListModel()
    private let connectivity = ConnectivityMonitor()
    private let statusItem = StatusItemController()
    private let overlay = OverlayController()
    private let settingsWindow = SettingsWindowController()
    private var onboardingWindow: NSWindow?
    private var levelTask: Task<Void, Never>?
    private var history: HistoryStore?

    private(set) var lastTranscript: String?
    /// The model currently loaded in the backend (nil while none is).
    private var activeModelID: String?
    /// Frontmost app when recording began — the injection target. If the
    /// frontmost app changes before injection, we refuse rather than type
    /// into the wrong window.
    private var recordingTargetPID: pid_t?
    private let clock = ContinuousClock()

    /// Recordings shorter than this are almost certainly an accidental tap.
    private let minimumUtteranceDuration: TimeInterval = 0.25

    func start() {
        connectivity.start()
        history = try? HistoryStore(
            url: FabPaths.applicationSupport.appendingPathComponent("history.sqlite")
        )
        if history == nil {
            NSLog("fabulous: history database unavailable; continuing without history")
        }

        statusItem.install(
            onOpenSettings: { [weak self] in self?.showSettings() },
            onShowSetup: { [weak self] in self?.showOnboarding() },
            onCopyLastTranscript: { [weak self] in self?.copyLastTranscript() }
        )
        hotkey.onPressBegan = { [weak self] in self?.hotkeyPressed() }
        hotkey.onPressEnded = { [weak self] in self?.hotkeyReleased() }
        hotkey.onEscapePressed = { [weak self] in
            guard let self else { return }
            Task { await self.cancelRecording() }
        }
        settings.onHotkeyChanged = { [weak self] in
            guard let self else { return }
            if hotkey.backend != .none {
                hotkey.start(spec: settings.hotkeySpec)
            }
            statusItem.update(for: state, hotkeyName: settings.hotkeySpec.displayName)
        }
        settings.onReplacementsChanged = { [weak self] in self?.rebuildPostProcessor() }
        rebuildPostProcessor()

        if Permissions.allGranted {
            activateDictation()
        } else {
            state = .needsPermissions
            showOnboarding()
        }
    }

    /// Called once permissions are in place (at launch or from onboarding).
    private func activateDictation() {
        hotkey.start(spec: settings.hotkeySpec)
        NSLog("fabulous: hotkey backend = \(hotkey.backend.rawValue)")
        Task { await ensureSelectedModelLoaded() }
    }

    // MARK: - Model lifecycle

    private var selectedModel: ModelDescriptor {
        ModelCatalog.descriptor(withID: settings.selectedModelID) ?? ModelCatalog.recommended
    }

    private func ensureSelectedModelLoaded() async {
        let model = selectedModel
        do {
            if await !modelManager.isInstalled(model) {
                try await downloadModel(model, drivesAppState: true)
            }
            state = .loadingModel(nil)
            try await backend.load(model: model)
            activeModelID = model.id
            state = .idle
        } catch ModelManager.ManagerError.offline {
            state = .failed("Offline — can't download \(model.displayName). Connect and retry from Settings → Models.")
        } catch {
            state = .failed("Model load failed: \(error.localizedDescription)")
        }
        await refreshModelList()
    }

    /// Downloads with progress reflected in the Models tab, and optionally
    /// in the menu bar (used for the automatic first-launch download).
    private func downloadModel(_ model: ModelDescriptor, drivesAppState: Bool) async throws {
        modelList.update(model.id, to: .downloading(0))
        if drivesAppState { state = .loadingModel(0) }
        do {
            try await modelManager.download(model) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.noteDownloadProgress(model, fraction, drivesAppState: drivesAppState)
                }
            }
        } catch {
            modelList.update(model.id, to: .failed(shortErrorText(error)))
            throw error
        }
    }

    private var lastReportedFraction: Double = 0

    private func noteDownloadProgress(_ model: ModelDescriptor, _ fraction: Double, drivesAppState: Bool) {
        // The hub client reports very chatty progress; only repaint on
        // visible change.
        guard fraction >= 1 || fraction - lastReportedFraction > 0.01 else { return }
        lastReportedFraction = fraction >= 1 ? 0 : fraction
        modelList.update(model.id, to: .downloading(fraction))
        if drivesAppState { state = .loadingModel(fraction) }
    }

    private func refreshModelList() async {
        for descriptor in ModelCatalog.all {
            if case .downloading = modelList.items.first(where: { $0.id == descriptor.id })?.status {
                continue // don't clobber an in-flight download row
            }
            if await modelManager.isInstalled(descriptor) {
                let bytes = await modelManager.sizeOnDisk(descriptor)
                let megabytes = bytes.map { Int($0 / 1_048_576) }
                modelList.update(
                    descriptor.id,
                    to: descriptor.id == activeModelID ? .active : .installed,
                    sizeOnDiskMB: .some(megabytes)
                )
            } else {
                modelList.update(descriptor.id, to: .notInstalled, sizeOnDiskMB: .some(nil))
            }
        }
    }

    // MARK: - Settings actions

    private func showSettings() {
        settingsWindow.show(
            store: settings,
            models: modelList,
            connectivity: connectivity,
            actions: SettingsActions(
                setHotkeyCapturing: { [weak self] capturing in
                    self?.hotkey.isSuspended = capturing
                },
                downloadModel: { [weak self] model in
                    Task { [weak self] in
                        try? await self?.downloadModel(model, drivesAppState: false)
                        await self?.refreshModelList()
                    }
                },
                deleteModel: { [weak self] model in
                    Task { [weak self] in
                        guard let self else { return }
                        try? await modelManager.delete(model)
                        await refreshModelList()
                    }
                },
                useModel: { [weak self] model in
                    Task { [weak self] in await self?.switchModel(to: model) }
                },
                recentTranscripts: { [weak self] in
                    (try? self?.history?.recent(limit: 50)) ?? []
                },
                clearHistory: { [weak self] in
                    try? self?.history?.clear()
                }
            )
        )
        Task { await refreshModelList() }
    }

    private func switchModel(to model: ModelDescriptor) async {
        guard state == .idle || isFailed(state) else { return }
        state = .loadingModel(nil)
        do {
            try await backend.load(model: model)
            activeModelID = model.id
            settings.selectedModelID = model.id
            state = .idle
        } catch {
            state = .failed("Couldn't switch model: \(shortErrorText(error))")
        }
        await refreshModelList()
    }

    private func isFailed(_ state: State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: - Push-to-talk state machine

    private func hotkeyPressed() {
        switch (settings.hotkeySpec.mode, state) {
        case (.pushToTalk, .idle), (.toggle, .idle):
            Task { await beginRecording() }
        case (.toggle, .recording):
            Task { await finishRecording() }
        default:
            break
        }
    }

    private func hotkeyReleased() {
        guard settings.hotkeySpec.mode == .pushToTalk, state == .recording else { return }
        Task { await finishRecording() }
    }

    private func beginRecording() async {
        guard Permissions.microphoneGranted else {
            showOnboarding()
            return
        }
        do {
            try await recorder.start(deviceUID: settings.inputDeviceUID)
            recordingTargetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            hotkey.interceptEscape = true
            state = .recording
            overlay.showRecording()
            startLevelUpdates()
            if settings.soundCuesEnabled { SoundCues.recordingStarted() }
        } catch {
            await flashFailure("Couldn't start recording: \(error)")
        }
    }

    /// Esc during recording: discard everything, transcribe nothing.
    private func cancelRecording() async {
        guard state == .recording else { return }
        hotkey.interceptEscape = false
        stopLevelUpdates()
        var audio = await recorder.stop()
        audio.zero()
        state = .idle
        overlay.hide()
        if settings.soundCuesEnabled { SoundCues.recordingCancelled() }
    }

    private func finishRecording() async {
        let releasedAt = clock.now
        hotkey.interceptEscape = false
        stopLevelUpdates()
        if settings.soundCuesEnabled { SoundCues.recordingStopped() }
        var audio = await recorder.stop()
        defer { audio.zero() }
        let stoppedAt = clock.now

        guard audio.duration >= minimumUtteranceDuration else {
            state = .idle
            overlay.hide()
            return
        }
        state = .transcribing
        overlay.showTranscribing()
        do {
            let overlay = self.overlay
            let transcript = try await backend.transcribe(audio, language: nil) { fraction in
                overlay.updateProgress(fraction)
            }
            let transcribedAt = clock.now
            let text = try await postProcessor.process(transcript.text)
            let processedAt = clock.now
            guard !text.isEmpty else {
                state = .idle
                overlay.hide()
                return
            }
            lastTranscript = text
            statusItem.setLastTranscriptAvailable(true)
            recordHistory(text: text, audioSeconds: audio.duration)

            await deliver(text)
            let deliveredAt = clock.now

            state = .idle
            noteMetrics(DictationMetrics(
                audioDuration: audio.duration,
                stopAndTrim: stoppedAt - releasedAt,
                transcription: transcribedAt - stoppedAt,
                postProcessing: processedAt - transcribedAt,
                delivery: deliveredAt - processedAt,
                total: deliveredAt - releasedAt
            ))
        } catch {
            overlay.hide()
            await flashFailure("Transcription failed: \(error)")
        }
    }

    /// Injects the transcript — or, when injection is impossible (focus
    /// moved, secure input, all strategies failed), runs the safety net:
    /// the text goes to the clipboard and the pill says why. A transcript
    /// is never silently lost.
    private func deliver(_ text: String) async {
        if let target = recordingTargetPID,
           let current = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           current != target
        {
            safetyNet(text, notice: "Focus changed — transcript copied to clipboard")
            return
        }
        do {
            try await injector.inject(text)
            overlay.hide()
        } catch let InjectionError.refused(reason) {
            let notice = switch reason {
            case .secureInputActive:
                "Password field — transcript copied to clipboard"
            case .accessibilityNotGranted:
                "Accessibility revoked — transcript copied to clipboard"
            }
            safetyNet(text, notice: notice)
        } catch {
            safetyNet(text, notice: "Couldn't insert — transcript copied to clipboard")
        }
    }

    private func safetyNet(_ text: String, notice: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        overlay.showMessage(notice)
        NSLog("fabulous: safety net — \(notice)")
    }

    private func startLevelUpdates() {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let level = await recorder.currentLevel
                overlay.updateLevel(level)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopLevelUpdates() {
        levelTask?.cancel()
        levelTask = nil
    }

    private func noteMetrics(_ metrics: DictationMetrics) {
        statusItem.setMetrics(metrics.menuSummary)
        NSLog("fabulous: \(metrics.logLine)")
        if metrics.exceedsBudget() {
            NSLog("fabulous: latency budget exceeded (>1.5 s) — see spec phase-3")
        }
    }

    private func rebuildPostProcessor() {
        let entries = settings.replacementEntries.filter { !$0.pattern.isEmpty }
        postProcessor = entries.isEmpty
            ? PassthroughPostProcessor()
            : ReplacementDictionary(entries: entries)
    }

    private func recordHistory(text: String, audioSeconds: TimeInterval) {
        guard settings.historyEnabled, let history else { return }
        do {
            try history.record(
                text: text,
                audioSeconds: audioSeconds,
                modelID: activeModelID ?? "unknown",
                cap: settings.historyCap
            )
        } catch {
            NSLog("fabulous: failed to record history: \(error)")
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

    private func shortErrorText(_ error: Error) -> String {
        if case ModelManager.ManagerError.offline = error {
            return "You appear to be offline."
        }
        return (error as NSError).localizedDescription
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
        let view = OnboardingView(hotkeyName: settings.hotkeySpec.displayName) { [weak self] in
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
