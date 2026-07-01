import AppKit
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
            window.title = "fabulous Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
