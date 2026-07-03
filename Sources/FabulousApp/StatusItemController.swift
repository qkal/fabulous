import AppKit

/// The menu bar presence: an SF Symbol reflecting the dictation state and a
/// small menu. Deliberately dumb — it renders state, it doesn't own any.
@MainActor
final class StatusItemController {
    private var statusItem: NSStatusItem?
    private let stateItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let metricsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let statsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cleanupStatsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let deliveryStatsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let copyItem = NSMenuItem(
        title: "Copy Last Transcript",
        action: #selector(copyLastTranscript),
        keyEquivalent: ""
    )
    private let settingsItem = NSMenuItem(
        title: "Settings…",
        action: #selector(openSettings),
        keyEquivalent: ","
    )
    private let setupItem = NSMenuItem(
        title: "Permissions Setup…",
        action: #selector(showSetup),
        keyEquivalent: ""
    )

    private var onOpenSettings: (() -> Void)?
    private var onShowSetup: (() -> Void)?
    private var onCopyLastTranscript: (() -> Void)?

    func install(
        onOpenSettings: @escaping () -> Void,
        onShowSetup: @escaping () -> Void,
        onCopyLastTranscript: @escaping () -> Void
    ) {
        self.onOpenSettings = onOpenSettings
        self.onShowSetup = onShowSetup
        self.onCopyLastTranscript = onCopyLastTranscript

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        let menu = NSMenu()
        stateItem.isEnabled = false
        hintItem.isEnabled = false
        metricsItem.isEnabled = false
        metricsItem.isHidden = true // until the first dictation
        statsItem.isEnabled = false
        statsItem.isHidden = true // until stats exist for the active engine
        cleanupStatsItem.isEnabled = false
        cleanupStatsItem.isHidden = true // until an LLM-cleaned dictation exists
        deliveryStatsItem.isEnabled = false
        deliveryStatsItem.isHidden = true // until a post-v6 dictation exists
        copyItem.target = self
        copyItem.isEnabled = false
        settingsItem.target = self
        setupItem.target = self

        let quitItem = NSMenuItem(
            title: "Quit fabulous",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        menu.items = [
            stateItem,
            hintItem,
            metricsItem,
            statsItem,
            cleanupStatsItem,
            deliveryStatsItem,
            .separator(),
            copyItem,
            settingsItem,
            setupItem,
            .separator(),
            quitItem,
        ]
        menu.autoenablesItems = false
        item.menu = menu
    }

    func update(for state: AppController.State, hotkeyName: String) {
        // Waveform is the app's identity in the menu bar — distinctive next
        // to a row of generic glyphs, and it *is* what the app does. Each
        // symbol carries a fallback in case the badge variant is missing.
        let (symbol, fallback, description, stateText): (String, String, String, String) = switch state {
        case .needsPermissions:
            ("waveform.badge.exclamationmark", "mic.slash",
             "fabulous — needs permissions", "Waiting for permissions")
        case let .loadingModel(progress):
            (
                "arrow.down.circle.dotted", "arrow.down.circle",
                "fabulous — loading model",
                progress.map {
                    "Downloading model… \($0.formatted(.percent.precision(.fractionLength(0))))"
                } ?? "Loading model…"
            )
        case .idle:
            ("waveform.badge.microphone", "waveform",
             "fabulous — ready", "Ready")
        case .recording:
            ("waveform", "waveform.circle.fill",
             "fabulous — recording", "Recording…")
        case .transcribing:
            ("waveform.badge.magnifyingglass", "ellipsis.circle",
             "fabulous — transcribing", "Transcribing…")
        case let .failed(message):
            ("exclamationmark.triangle", "exclamationmark.triangle",
             "fabulous — error", message)
        }

        statusItem?.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: description
        ) ?? NSImage(systemSymbolName: fallback, accessibilityDescription: description)
        stateItem.title = stateText
        hintItem.title = "Hold \(hotkeyName) to dictate"
    }

    func setLastTranscriptAvailable(_ available: Bool) {
        copyItem.isEnabled = available
    }

    func setMetrics(_ summary: String) {
        metricsItem.title = summary
        metricsItem.isHidden = false
    }

    /// Aggregate p50/p90 line under the last-dictation line; nil hides it
    /// (e.g. right after switching to an engine with no samples yet).
    func setLatencyStats(_ summary: String?) {
        statsItem.title = summary ?? ""
        statsItem.isHidden = summary == nil
    }

    /// LLM cleanup p50/p90 + fallback line under the latency line; nil hides
    /// it (cleanup never ran, or metrics store unavailable).
    func setCleanupStats(_ summary: String?) {
        cleanupStatsItem.title = summary ?? ""
        cleanupStatsItem.isHidden = summary == nil
    }

    /// Delivery-method share + p50 line under the cleanup line; nil hides
    /// it (no post-migration dictations, or metrics store unavailable).
    func setDeliveryStats(_ summary: String?) {
        deliveryStatsItem.title = summary ?? ""
        deliveryStatsItem.isHidden = summary == nil
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func showSetup() {
        onShowSetup?()
    }

    @objc private func copyLastTranscript() {
        onCopyLastTranscript?()
    }
}
