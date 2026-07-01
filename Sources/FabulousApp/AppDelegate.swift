import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement in Info.plist keeps us out of the Dock; set the policy
        // explicitly too so `swift run` (bare binary, no bundle) behaves.
        NSApp.setActivationPolicy(.accessory)
        controller.start()
    }
}
