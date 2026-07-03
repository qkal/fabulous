import SwiftUI

/// Walks through the two required permissions with live status checks.
/// Shown on first launch and reachable from the menu bar afterwards.
struct OnboardingView: View {
    @State private var microphoneGranted = Permissions.microphoneGranted
    @State private var microphoneDenied = Permissions.microphoneDenied
    @State private var accessibilityTrusted = Permissions.accessibilityTrusted
    @State private var accessibilityPrompted = false

    let hotkeyName: String
    let onComplete: () -> Void

    private var allGranted: Bool { microphoneGranted && accessibilityTrusted }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to fabulous")
                    .font(.title.bold())
                Text("Hold \(hotkeyName) anywhere, speak, release — your words are typed into the app you're using. Everything runs on this Mac; audio never leaves it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            permissionRow(
                granted: microphoneGranted,
                title: "Microphone",
                detail: "Records only while you hold the hotkey."
            ) {
                if microphoneDenied {
                    Button("Open System Settings") {
                        Permissions.openMicrophoneSettings()
                    }
                } else {
                    Button("Grant Access") {
                        Task {
                            microphoneGranted = await Permissions.requestMicrophone()
                            microphoneDenied = Permissions.microphoneDenied
                        }
                    }
                }
            }

            permissionRow(
                granted: accessibilityTrusted,
                title: "Accessibility",
                detail: "Detects the hotkey and types the transcript for you."
            ) {
                Button(accessibilityPrompted ? "Open System Settings" : "Grant Access") {
                    if accessibilityPrompted {
                        Permissions.openAccessibilitySettings()
                    } else {
                        Permissions.promptAccessibility()
                        accessibilityPrompted = true
                    }
                }
            }

            HStack {
                Spacer()
                Button("Start Dictating") { onComplete() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!allGranted)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(PaperTheme.paper)
        .tint(PaperTheme.accent)
        .task {
            // Live status: Accessibility toggles flip in System Settings with
            // no notification API, so poll while the window is up.
            while !Task.isCancelled {
                microphoneGranted = Permissions.microphoneGranted
                microphoneDenied = Permissions.microphoneDenied
                accessibilityTrusted = Permissions.accessibilityTrusted
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private func permissionRow(
        granted: Bool,
        title: String,
        detail: String,
        @ViewBuilder action: () -> some View
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2)
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                action()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: PaperTheme.cardRadius)
                .fill(PaperTheme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: PaperTheme.cardRadius)
                        .strokeBorder(PaperTheme.hairline, lineWidth: 1)
                )
        )
    }
}
