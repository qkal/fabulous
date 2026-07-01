import AppKit
import ApplicationServices
import AVFoundation

/// Live checks and request/deep-link helpers for the two permissions the
/// vertical slice needs: Microphone (record) and Accessibility (hotkey tap,
/// AX insert, synthetic ⌘V).
@MainActor
enum Permissions {
    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var microphoneDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    static var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static var allGranted: Bool {
        microphoneGranted && accessibilityTrusted
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Shows the system "app would like to control this computer" prompt,
    /// which also adds fabulous to the Accessibility list pre-toggled off.
    static func promptAccessibility() {
        // kAXTrustedCheckOptionPrompt is a C global `var`, which Swift 6
        // strict concurrency rejects; its stable raw value is documented.
        let key = "AXTrustedCheckOptionPrompt"
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
