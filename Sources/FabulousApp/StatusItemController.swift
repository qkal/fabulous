import AppKit

/// The menu bar presence: an SF Symbol reflecting the dictation state and a
/// small menu. Deliberately dumb — it renders state, it doesn't own any.
@MainActor
final class StatusItemController {
    private var statusItem: NSStatusItem?
    private let stateItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let copyItem = NSMenuItem(
        title: "Copy Last Transcript",
        action: #selector(copyLastTranscript),
        keyEquivalent: ""
    )
    private let setupItem = NSMenuItem(
        title: "Permissions Setup…",
        action: #selector(showSetup),
        keyEquivalent: ""
    )

    private var onShowSetup: (() -> Void)?
    private var onCopyLastTranscript: (() -> Void)?

    func install(
        onShowSetup: @escaping () -> Void,
        onCopyLastTranscript: @escaping () -> Void
    ) {
        self.onShowSetup = onShowSetup
        self.onCopyLastTranscript = onCopyLastTranscript

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        let menu = NSMenu()
        stateItem.isEnabled = false
        hintItem.isEnabled = false
        copyItem.target = self
        copyItem.isEnabled = false
        setupItem.target = self

        let quitItem = NSMenuItem(
            title: "Quit fabulous",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        menu.items = [
            stateItem,
            hintItem,
            .separator(),
            copyItem,
            setupItem,
            .separator(),
            quitItem,
        ]
        menu.autoenablesItems = false
        item.menu = menu
    }

    func update(for state: AppController.State, hotkeyName: String) {
        let (symbol, description, stateText): (String, String, String) = switch state {
        case .needsPermissions:
            ("mic.slash", "fabulous — needs permissions", "Waiting for permissions")
        case .loadingModel:
            ("arrow.down.circle.dotted", "fabulous — loading model", "Downloading / loading model…")
        case .idle:
            ("mic", "fabulous — ready", "Ready")
        case .recording:
            ("waveform.circle.fill", "fabulous — recording", "Recording…")
        case .transcribing:
            ("ellipsis.circle", "fabulous — transcribing", "Transcribing…")
        case let .failed(message):
            ("exclamationmark.triangle", "fabulous — error", message)
        }

        statusItem?.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: description
        )
        stateItem.title = stateText
        hintItem.title = "Hold \(hotkeyName) to dictate"
    }

    func setLastTranscriptAvailable(_ available: Bool) {
        copyItem.isEnabled = available
    }

    @objc private func showSetup() {
        onShowSetup?()
    }

    @objc private func copyLastTranscript() {
        onCopyLastTranscript?()
    }
}
