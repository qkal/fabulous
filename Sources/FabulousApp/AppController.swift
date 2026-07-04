import AppKit
import AudioCapture
import FabCore
import HistoryStore
import HotkeyEngine
import PostProcessing
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
    private let whisperBackend = WhisperKitBackend()
    /// Created lazily on first use (macOS 26+ only).
    private var speechAnalyzerBackend: (any TranscriptionBackend)?
    private let parakeetBackend = ParakeetBackend()
    /// The backend dictations go through, per the engine preference.
    private var backend: any TranscriptionBackend {
        switch settings.transcriptionEngine {
        case .appleSpeech:
            return speechAnalyzerBackend ?? whisperBackend
        case .parakeet:
            return parakeetBackend
        case .whisper:
            return whisperBackend
        }
    }
    private let injector = TextInjector()
    private let hotkey = HotkeyMonitor()
    private let modelManager = ModelManager()
    // Rebuilt from the settings' replacement entries (deterministic replacements).
    // LLM cleanup (if enabled) runs first in `llmProcessor`, then this stage.
    private var postProcessor: any TextPostProcessor = PassthroughPostProcessor()
    /// LLM cleanup stage; nil when disabled or the model is unavailable.
    /// Runs before `postProcessor` so deterministic replacements win.
    private var llmProcessor: (any ContextualTextPostProcessor)?

    // App state & UI
    private let settings = SettingsStore()
    private let modelList = ModelListModel()
    private let connectivity = ConnectivityMonitor()
    private let statusItem = StatusItemController()
    private let overlay = OverlayController()
    private let settingsWindow = SettingsWindowController()
    private var onboardingWindow: NSWindow?
    private var levelTask: Task<Void, Never>?
    /// Live streaming session for the current utterance (streaming-capable engines).
    private var streamingSession: (any StreamingSession)?
    /// Creates the session off the critical path of `beginRecording`.
    private var sessionStartTask: Task<Void, Never>?
    /// Forwards session partials to the overlay.
    private var partialsTask: Task<Void, Never>?
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

    /// Glass is always dark — its fixed graphite surfaces need dark-mode
    /// native controls and label colors regardless of the appearance
    /// preference, which applies whenever the adaptive Paper theme is active.
    private func applyEffectiveAppearance() {
        NSApp.appearance = settings.theme == .glass
            ? NSAppearance(named: .darkAqua)
            : settings.appearance.nsAppearance
    }

    func start() {
        connectivity.start()
        applyEffectiveAppearance()
        overlay.applyTheme(Theme.current(settings.theme))
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
        settings.onAppOverridesChanged = { [weak self] in self?.applyInjectionOverrides() }
        settings.onLLMCleanupChanged = { [weak self] in self?.rebuildLLMProcessor() }
        settings.onEngineChanged = { [weak self] in
            guard let self, state == .idle || isFailed(state) else { return }
            Task { await self.ensureSelectedModelLoaded() }
        }
        settings.onThemeChanged = { [weak self] in
            guard let self else { return }
            applyEffectiveAppearance()
            let theme = Theme.current(settings.theme)
            overlay.applyTheme(theme)
            settingsWindow.refreshBackground(theme.paperNSColor)
            onboardingWindow?.backgroundColor = theme.paperNSColor
        }
        settings.onAppearanceChanged = { [weak self] in
            guard let self else { return }
            applyEffectiveAppearance()
        }
        rebuildPostProcessor()
        rebuildLLMProcessor()
        applyInjectionOverrides()

        Task { await upgradeVAD() }

        if Permissions.allGranted {
            activateDictation()
        } else {
            state = .needsPermissions
            showOnboarding()
        }
    }

    /// Best-effort upgrade from the energy heuristic to Silero VAD. Offline
    /// or failed? The recorder just keeps trimming with EnergyVAD.
    private func upgradeVAD() async {
        do {
            let modelURL = try await SileroVADInstaller.installIfNeeded()
            let vad = try SileroVAD(modelURL: modelURL)
            await recorder.setVAD(vad)
            NSLog("fabulous: Silero VAD active")
        } catch {
            NSLog("fabulous: Silero VAD unavailable (\(error)); staying on energy VAD")
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
        ModelCatalog.whisperVariants.first { $0.id == settings.selectedModelID }
            ?? ModelCatalog.recommended
    }

    private func ensureSelectedModelLoaded() async {
        switch settings.transcriptionEngine {
        case .whisper: await loadWhisper()
        case .appleSpeech: await loadAppleSpeech()
        case .parakeet: await loadParakeet()
        }
    }

    private func loadWhisper() async {
        // Free the inactive engines; keep-warm applies to the active one only.
        if let inactive = speechAnalyzerBackend { await inactive.unload() }
        await parakeetBackend.unload()
        let model = selectedModel
        do {
            if await !modelManager.isInstalled(model) {
                try await downloadModel(model, drivesAppState: true)
            }
            state = .loadingModel(nil)
            try await whisperBackend.load(model: model)
            activeModelID = model.id
            state = .idle
            refreshLatencyStats()
        } catch ModelManager.ManagerError.offline {
            state = .failed("Offline — can't download \(model.displayName). Connect and retry from Settings → Models.")
        } catch {
            state = .failed("Model load failed: \(error.localizedDescription)")
        }
        await refreshModelList()
    }

    /// Loads the Apple Speech engine; any failure reverts the preference and
    /// falls back to Whisper so dictation keeps working.
    private func loadAppleSpeech() async {
        guard #available(macOS 26.0, *) else {
            state = .loadingModel(nil)
            settings.transcriptionEngine = .whisper
            await flashFailure("Apple Speech needs macOS 26 — using Whisper")
            await loadWhisper()
            return
        }
        // Whisper's multi-GB model has no business staying resident while
        // another engine handles dictation.
        await whisperBackend.unload()
        await parakeetBackend.unload()
        state = .loadingModel(nil)
        do {
            let engine = speechAnalyzerBackend ?? SpeechAnalyzerBackend()
            try await engine.load(model: .appleSpeech)
            speechAnalyzerBackend = engine
            activeModelID = ModelDescriptor.appleSpeech.id
            state = .idle
            refreshLatencyStats()
        } catch {
            // Reverting the preference fires onEngineChanged, but that
            // callback no-ops outside .idle/.failed — the explicit
            // loadWhisper below is what actually restores dictation.
            settings.transcriptionEngine = .whisper
            await flashFailure("Apple Speech failed (\(shortErrorText(error))) — using Whisper")
            await loadWhisper()
        }
        await refreshModelList()
    }

    /// Loads Parakeet, auto-downloading its model sets on first use; any
    /// failure reverts the preference and falls back to Whisper so
    /// dictation keeps working.
    private func loadParakeet() async {
        await whisperBackend.unload()
        if let inactive = speechAnalyzerBackend { await inactive.unload() }
        do {
            if await !modelManager.isInstalled(.parakeetV3) {
                try await downloadModel(.parakeetV3, drivesAppState: true)
            }
            state = .loadingModel(nil)
            try await parakeetBackend.load(model: .parakeetV3)
            activeModelID = ModelDescriptor.parakeetV3.id
            state = .idle
            refreshLatencyStats()
        } catch ModelManager.ManagerError.offline {
            settings.transcriptionEngine = .whisper
            await flashFailure("Offline — can't download Parakeet. Using Whisper")
            await loadWhisper()
        } catch {
            settings.transcriptionEngine = .whisper
            await flashFailure("Parakeet failed (\(shortErrorText(error))) — using Whisper")
            await loadWhisper()
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
                    Task { [weak self] in
                        guard let self else { return }
                        if model.id == ModelDescriptor.parakeetV3.id {
                            guard state == .idle || isFailed(state) else { return }
                            // Fires onEngineChanged, which loads Parakeet.
                            settings.transcriptionEngine = .parakeet
                        } else {
                            await switchModel(to: model)
                        }
                    }
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
        // Picking a Whisper variant is an implicit engine choice. Setting the
        // preference here is safe: onEngineChanged no-ops while loading.
        settings.transcriptionEngine = .whisper
        if let inactive = speechAnalyzerBackend { await inactive.unload() }
        await parakeetBackend.unload()
        do {
            try await whisperBackend.load(model: model)
            activeModelID = model.id
            settings.selectedModelID = model.id
            state = .idle
            refreshLatencyStats()
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
            // Warm the cleanup session while the user speaks: the session
            // and its instructions prefix are ready when transcription ends.
            // Fire-and-forget — prewarm is opportunistic, never blocking.
            if let llmProcessor {
                Task {
                    await llmProcessor.setAppContext(name: recordingTargetAppName())
                    await llmProcessor.prepare()
                }
            }
            hotkey.interceptEscape = true
            state = .recording
            overlay.showRecording()
            startLevelUpdates()
            startStreamingSessionIfAvailable()
            if settings.soundCuesEnabled { SoundCues.recordingStarted() }
        } catch {
            await flashFailure("Couldn't start recording: \(error)")
        }
    }

    /// Opens a live session when the selected engine supports it. Runs
    /// concurrently so recording start is never delayed; samples accumulate
    /// in the tap and the first feed catches up via the drainNew cursor.
    /// Failure is silent — the batch path is untouched and always works.
    private func startStreamingSessionIfAvailable() {
        // Whisper is batch-only, so the cast is the whole engine check.
        guard let streamingBackend = backend as? any StreamingTranscriptionBackend
        else { return }
        sessionStartTask = Task { [weak self] in
            do {
                let session = try await streamingBackend.startStreamingSession()
                // Cancellation check matters: takeStreamingSession() cancels
                // then awaits this task while state is still .recording. A
                // session landing in that window would be stored but never
                // fed, then finish() returns empty and the utterance is lost.
                guard let self, !Task.isCancelled, state == .recording else {
                    await session.cancel()
                    return
                }
                streamingSession = session
                partialsTask = Task { [weak self] in
                    for await partial in session.partials {
                        guard !Task.isCancelled else { return }
                        self?.overlay.updatePartial(partial)
                    }
                }
            } catch {
                NSLog("fabulous: streaming session unavailable, batch path (\(error))")
            }
        }
    }

    /// Esc during recording: discard everything, transcribe nothing.
    private func cancelRecording() async {
        guard state == .recording else { return }
        hotkey.interceptEscape = false
        stopLevelUpdates()
        if let session = await takeStreamingSession() { await session.cancel() }
        var audio = await recorder.stop()
        audio.zero()
        state = .idle
        overlay.hide()
        if settings.soundCuesEnabled { SoundCues.recordingCancelled() }
    }

    /// Stops the feed/partials machinery. Runs before any overlay
    /// transition so a late partial can never repaint a hidden pill.
    /// Returns the live session (if any) for finish/cancel; clears fields.
    private func takeStreamingSession() async -> (any StreamingSession)? {
        sessionStartTask?.cancel()
        // Let a mid-flight start finish or observe cancellation before we
        // read the field, so a session can't appear after we've looked.
        await sessionStartTask?.value
        sessionStartTask = nil
        partialsTask?.cancel()
        partialsTask = nil
        let session = streamingSession
        streamingSession = nil
        return session
    }

    private func finishRecording() async {
        let releasedAt = clock.now
        hotkey.interceptEscape = false
        stopLevelUpdates()
        if settings.soundCuesEnabled { SoundCues.recordingStopped() }
        let session = await takeStreamingSession()
        // Feed the final audio tail — samples captured since the last 250 ms
        // feed tick — so the session hears the last syllables before we stop.
        if let session {
            let tail = await recorder.pollNewSamples()
            if !tail.isEmpty { await session.feed(tail) }
        }
        // Streaming path: stop untrimmed — the trimmed buffer would go
        // unused and Silero at release costs exactly the latency this
        // phase removes. Trim lazily only if we fall back to batch.
        //
        // `audioIsRaw` records whether stop returned an untrimmed buffer: it
        // did iff a session existed. The batch fallback trims only when raw;
        // when session == nil the buffer is already VAD-trimmed and a second
        // pass would recharge latency and re-shave padding (Whisper would hear
        // different audio than the pre-branch behaviour).
        let audioIsRaw = session != nil
        var audio = await recorder.stop(trimming: session == nil)
        defer { audio.zero() }
        let stoppedAt = clock.now

        guard audio.duration >= minimumUtteranceDuration else {
            if let session { await session.cancel() }
            state = .idle
            overlay.hide()
            return
        }
        state = .transcribing
        overlay.showTranscribing()
        do {
            let capturedAudio = audio
            let batchBackend = backend
            let (transcript, streamed) = try await StreamingDictation.finalTranscript(
                session: session,
                fallback: { [recorder] in
                    // Raw buffer (a session existed at stop) still needs its
                    // one VAD pass; a pre-trimmed buffer is used as-is — the
                    // recorder already returns empty when VAD heard nothing.
                    if audioIsRaw {
                        var trimmed = await recorder.trimSilence(capturedAudio)
                        defer { trimmed.zero() }
                        guard !trimmed.isEmpty else {
                            return Transcript(text: "", audioDuration: 0)
                        }
                        return try await batchBackend.transcribe(trimmed, language: nil)
                    }
                    guard !capturedAudio.isEmpty else {
                        return Transcript(text: "", audioDuration: 0)
                    }
                    return try await batchBackend.transcribe(capturedAudio, language: nil)
                }
            )
            let transcribedAt = clock.now
            let rawText = transcript.text
            var cleaned = rawText
            var llmOutcome = LLMCleanupOutcome.off
            // The model may have become available since launch (e.g. it was
            // still downloading) — cheap re-check so cleanup doesn't stay
            // dead until restart.
            if llmProcessor == nil, settings.llmCleanupEnabled {
                rebuildLLMProcessor()
            }
            if let llmProcessor {
                await llmProcessor.setAppContext(name: recordingTargetAppName())
                let report = await llmProcessor.cleanup(rawText)
                cleaned = report.text
                llmOutcome = report.outcome
            }
            let llmDoneAt = clock.now
            let text = try await postProcessor.process(cleaned)
            let processedAt = clock.now
            guard !text.isEmpty else {
                state = .idle
                overlay.hide()
                return
            }
            lastTranscript = text
            statusItem.setLastTranscriptAvailable(true)
            recordHistory(
                text: text,
                rawText: llmOutcome == .changed ? rawText : nil,
                audioSeconds: transcript.audioDuration ?? audio.duration
            )

            let deliveryMethod = await deliver(text)
            let deliveredAt = clock.now

            state = .idle
            noteMetrics(DictationMetrics(
                audioDuration: transcript.audioDuration ?? audio.duration,
                stopAndTrim: stoppedAt - releasedAt,
                transcription: transcribedAt - stoppedAt,
                llmCleanup: llmOutcome == .off ? .zero : llmDoneAt - transcribedAt,
                llmOutcome: llmOutcome,
                postProcessing: processedAt - llmDoneAt,
                delivery: deliveredAt - processedAt,
                total: deliveredAt - releasedAt,
                streamed: streamed,
                deliveryMethod: deliveryMethod
            ))
        } catch {
            overlay.hide()
            await flashFailure("Transcription failed: \(error)")
        }
    }

    /// Injects the transcript — or, when injection is impossible (focus
    /// moved, secure input, all strategies failed), runs the safety net:
    /// the text goes to the clipboard and the pill says why. A transcript
    /// is never silently lost. Returns how the text was delivered.
    private func deliver(_ text: String) async -> DeliveryMethod {
        if let target = recordingTargetPID,
           let current = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           current != target
        {
            safetyNet(text, notice: "Focus changed — transcript copied to clipboard")
            return .safetyNet
        }
        do {
            let strategy = try await injector.inject(text)
            overlay.hide()
            // Raw values are aligned by test; fallback label can't be hit
            // without that test failing first.
            return DeliveryMethod(rawValue: strategy.rawValue) ?? .safetyNet
        } catch let InjectionError.refused(reason) {
            let notice = switch reason {
            case .secureInputActive:
                "Password field — transcript copied to clipboard"
            case .accessibilityNotGranted:
                "Accessibility revoked — transcript copied to clipboard"
            }
            safetyNet(text, notice: notice)
            return .safetyNet
        } catch {
            safetyNet(text, notice: "Couldn't insert — transcript copied to clipboard")
            return .safetyNet
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
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                let level = await recorder.currentLevel
                overlay.updateLevel(level)
                // Every 5th tick (~250 ms): feed fresh samples to the live
                // session. The session ignores feeds after finish/cancel.
                tick += 1
                if tick % 5 == 0, let session = streamingSession {
                    let fresh = await recorder.pollNewSamples()
                    if !fresh.isEmpty { await session.feed(fresh) }
                }
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
        persistMetrics(metrics)
    }

    /// Numbers-only persistence, independent of the transcript-history
    /// toggle: without it, the "decide the engine with data" plan dies the
    /// way it did in phase 3 (NSLog-only metrics evaporated).
    private func persistMetrics(_ metrics: DictationMetrics) {
        guard let history else { return }
        let engineID = activeModelID ?? "unknown"
        do {
            try history.recordMetrics(MetricsEntry(
                createdAt: Date(),
                engineID: engineID,
                audioSeconds: metrics.audioDuration,
                stopTrimMs: DictationMetrics.milliseconds(metrics.stopAndTrim),
                asrMs: DictationMetrics.milliseconds(metrics.transcription),
                postMs: DictationMetrics.milliseconds(metrics.postProcessing),
                deliveryMs: DictationMetrics.milliseconds(metrics.delivery),
                totalMs: DictationMetrics.milliseconds(metrics.total),
                streamed: metrics.streamed,
                llmMs: DictationMetrics.milliseconds(metrics.llmCleanup),
                llmOutcome: metrics.llmOutcome,
                deliveryMethod: metrics.deliveryMethod
            ))
            let stats = try history.latencyStats(engineID: engineID)
            statusItem.setLatencyStats(stats.map { Self.statsSummary($0, engineID: engineID) })
            let cleanupStats = try history.cleanupStats()
            statusItem.setCleanupStats(cleanupStats?.menuSummary)
            let deliveryStats = try history.deliveryStats()
            statusItem.setDeliveryStats(deliveryStats?.menuSummary)
        } catch {
            NSLog("fabulous: failed to record metrics: \(error)")
        }
    }

    /// Repaints the menu's p50/p90 line for the engine that just became
    /// active (hides it while that engine has no samples yet).
    private func refreshLatencyStats() {
        guard let history, let engineID = activeModelID else { return }
        let stats = try? history.latencyStats(engineID: engineID)
        statusItem.setLatencyStats(stats.map { Self.statsSummary($0, engineID: engineID) })
        let cleanupStats = try? history.cleanupStats()
        statusItem.setCleanupStats(cleanupStats?.menuSummary)
        let deliveryStats = try? history.deliveryStats()
        statusItem.setDeliveryStats(deliveryStats?.menuSummary)
    }

    /// e.g. "Whisper Large v3 Turbo · p50 1.12 s · p90 1.48 s · 42 runs"
    static func statsSummary(_ stats: LatencyStats, engineID: String) -> String {
        let name = ModelCatalog.descriptor(withID: engineID)?.displayName ?? engineID
        let p50 = String(format: "%.2f", stats.p50TotalMs / 1000)
        let p90 = String(format: "%.2f", stats.p90TotalMs / 1000)
        return "\(name) · p50 \(p50) s · p90 \(p90) s · \(stats.sampleCount) run\(stats.sampleCount == 1 ? "" : "s")"
    }

    private func rebuildPostProcessor() {
        let entries = settings.replacementEntries.filter { !$0.pattern.isEmpty }
        postProcessor = entries.isEmpty
            ? PassthroughPostProcessor()
            : ReplacementDictionary(entries: entries)
    }

    /// Pushes the current per-app overrides into the injector. The
    /// injector instance is deliberately kept — recreating it would drop
    /// a pending clipboard restore.
    private func applyInjectionOverrides() {
        injector.selector = StrategySelector(userOverrides: settings.appOverrideEntries)
    }

    /// (Re)creates the LLM stage. Vocabulary is baked into the instructions,
    /// so a vocabulary edit also lands here via onLLMCleanupChanged.
    private func rebuildLLMProcessor() {
        guard settings.llmCleanupEnabled,
              PostProcessingAvailability.current == .available,
              #available(macOS 26.0, *)
        else {
            llmProcessor = nil
            return
        }
        llmProcessor = FoundationModelPostProcessor(
            requester: FoundationModelRequester(),
            vocabulary: settings.llmVocabulary
        )
        FoundationModelRequester.prewarm()
    }

    /// Name of the app dictation started in — the injection target.
    private func recordingTargetAppName() -> String? {
        recordingTargetPID.flatMap {
            NSRunningApplication(processIdentifier: $0)?.localizedName
        }
    }

    private func recordHistory(text: String, rawText: String?, audioSeconds: TimeInterval) {
        guard settings.historyEnabled, let history else { return }
        do {
            try history.record(
                text: text,
                rawText: rawText,
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
        let view = OnboardingView(store: settings, hotkeyName: settings.hotkeySpec.displayName) { [weak self] in
            guard let self else { return }
            onboardingWindow?.close()
            if case .needsPermissions = state {
                activateDictation()
            }
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "fabulous"
        window.styleMask = [.titled, .closable]
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.current(settings.theme).paperNSColor
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
