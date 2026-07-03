import AppKit
import FabCore
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(
        store: SettingsStore,
        models: ModelListModel,
        connectivity: ConnectivityMonitor,
        actions: SettingsActions
    ) {
        if window == nil {
            let view = SettingsRootView(
                store: store, models: models,
                connectivity: connectivity, actions: actions
            )
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "fabulous"
            // A real app window: resizable, minimizable, and it remembers
            // its size. An NSHostingController window with no explicit
            // content size collapses to the SwiftUI intrinsic height (which
            // for a Form-in-navigation can be ~zero) — always set one.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.titlebarAppearsTransparent = true
            window.backgroundColor = PaperTheme.paperNSColor
            window.setContentSize(NSSize(width: 760, height: 520))
            window.contentMinSize = NSSize(width: 640, height: 420)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("fabulous.settings")
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
