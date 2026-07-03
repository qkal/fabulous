import AudioCapture
import FabCore
import HistoryStore
import HotkeyEngine
import SwiftUI

/// Closures into AppController — the views stay free of engine wiring.
struct SettingsActions {
    var setHotkeyCapturing: (Bool) -> Void
    var downloadModel: (ModelDescriptor) -> Void
    var deleteModel: (ModelDescriptor) -> Void
    var useModel: (ModelDescriptor) -> Void
    var recentTranscripts: () -> [TranscriptEntry]
    var clearHistory: () -> Void
}

/// Sidebar sections of the settings window — a real, resizable app window
/// with navigation, not a popup.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, models, replacements, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .models: "Models"
        case .replacements: "Replacements"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .models: "brain"
        case .replacements: "character.cursor.ibeam"
        case .history: "clock.arrow.circlepath"
        }
    }
}

struct SettingsRootView: View {
    @Bindable var store: SettingsStore
    let models: ModelListModel
    let connectivity: ConnectivityMonitor
    let actions: SettingsActions

    @State private var section: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .scrollContentBackground(.hidden)
            .background(PaperTheme.paper)
        } detail: {
            detailView
                .navigationTitle(section.title)
        }
        .background(PaperTheme.paper)
        .tint(PaperTheme.accent)
        .frame(minWidth: 640, minHeight: 420)
    }

    @ViewBuilder
    private var detailView: some View {
        switch section {
        case .general:
            GeneralSettingsPane(store: store, actions: actions)
        case .models:
            ModelsSettingsPane(
                store: store, models: models,
                connectivity: connectivity, actions: actions
            )
        case .replacements:
            ReplacementsSettingsPane(store: store)
        case .history:
            HistorySettingsPane(store: store, actions: actions)
        }
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @Bindable var store: SettingsStore
    let actions: SettingsActions

    @State private var capturing = false
    @State private var captureSession = KeyCaptureSession()
    @State private var devices: [CaptureDevice] = []
    @State private var launchAtLogin = false
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("Dictation hotkey") {
                LabeledContent("Shortcut") {
                    HStack {
                        Text(capturing ? "Press hotkey… (⎋ to cancel)" : store.hotkeySpec.displayName)
                            .font(.body.monospaced())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(capturing ? Color.accentColor : Color.secondary.opacity(0.4))
                            )
                        Button(capturing ? "Cancel" : "Change…") {
                            capturing ? cancelCapture() : beginCapture()
                        }
                    }
                }
                Picker("Mode", selection: $store.hotkeySpec.mode) {
                    ForEach(HotkeySpec.Mode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Audio") {
                Picker("Microphone", selection: $store.inputDeviceUID) {
                    Text("System Default").tag(String?.none)
                    ForEach(devices) { device in
                        Text(device.name).tag(String?.some(device.id))
                    }
                }
                Toggle("Play sound when recording starts and stops", isOn: $store.soundCuesEnabled)
            }

            if #available(macOS 26.0, *) {
                Section("Transcription") {
                    Picker("Engine", selection: $store.transcriptionEngine) {
                        ForEach(TranscriptionEngineKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    Text("Apple Speech uses the system's on-device recognizer — faster, but accuracy may differ. Whisper models are picked in the Models tab.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Launch fabulous at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        guard newValue != LaunchAtLogin.isEnabled else { return }
                        do {
                            try LaunchAtLogin.set(newValue)
                            launchAtLoginError = nil
                        } catch {
                            launchAtLogin = LaunchAtLogin.isEnabled
                            launchAtLoginError = error.localizedDescription
                        }
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(PaperTheme.paper)
        .onAppear {
            devices = AudioDevices.inputDevices()
            launchAtLogin = LaunchAtLogin.isEnabled
        }
        .onDisappear { cancelCapture() }
    }

    private func beginCapture() {
        capturing = true
        actions.setHotkeyCapturing(true)
        captureSession.begin { trigger in
            capturing = false
            actions.setHotkeyCapturing(false)
            if let trigger {
                store.hotkeySpec.trigger = trigger
            }
        }
    }

    private func cancelCapture() {
        guard capturing else { return }
        captureSession.end()
        capturing = false
        actions.setHotkeyCapturing(false)
    }
}

// MARK: - Models

private struct ModelsSettingsPane: View {
    @Bindable var store: SettingsStore
    let models: ModelListModel
    let connectivity: ConnectivityMonitor
    let actions: SettingsActions

    var body: some View {
        Form {
            if !connectivity.isOnline {
                Section {
                    Label(
                        "You're offline. Installed models keep working; downloads will resume when you're back online.",
                        systemImage: "wifi.slash"
                    )
                    .foregroundStyle(.orange)
                }
            }
            Section("Models") {
                ForEach(models.items) { item in
                    ModelRow(
                        item: item,
                        isRecommended: item.descriptor == ModelCatalog.recommended,
                        isOnline: connectivity.isOnline,
                        actions: actions
                    )
                }
            }
            Section {
                Text("Models run entirely on this Mac. Downloads come from Hugging Face (argmaxinc/whisperkit-coreml) into ~/Library/Application Support/fabulous/models/.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(PaperTheme.paper)
    }
}

private struct ModelRow: View {
    let item: ModelListModel.Item
    let isRecommended: Bool
    let isOnline: Bool
    let actions: SettingsActions

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.descriptor.displayName).font(.headline)
                    if isRecommended {
                        Text("Recommended")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                }
                Text(sizeText).font(.caption).foregroundStyle(.secondary)
                if case let .failed(message) = item.status {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            statusControls
        }
        .padding(.vertical, 2)
    }

    private var sizeText: String {
        if let size = item.sizeOnDiskMB {
            "\(size) MB on disk"
        } else {
            "~\(item.descriptor.approximateSizeMB) MB download"
        }
    }

    @ViewBuilder
    private var statusControls: some View {
        switch item.status {
        case .notInstalled, .failed:
            Button("Download") { actions.downloadModel(item.descriptor) }
                .disabled(!isOnline)
        case let .downloading(progress):
            HStack(spacing: 8) {
                ProgressView(value: progress).frame(width: 100)
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .installed:
            HStack(spacing: 8) {
                Button("Use") { actions.useModel(item.descriptor) }
                Button(role: .destructive) {
                    actions.deleteModel(item.descriptor)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this model from disk")
            }
        case .active:
            Label("Active", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}

// MARK: - Replacements

private struct ReplacementsSettingsPane: View {
    @Bindable var store: SettingsStore

    @State private var newPattern = ""
    @State private var newReplacement = ""

    var body: some View {
        Form {
            Section {
                Text("Whole-word fixes applied to every transcript — project names, jargon, anything the model keeps mishearing. Case-insensitive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Add replacement") {
                HStack {
                    TextField("heard as… (e.g. anthropite)", text: $newPattern)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("replace with… (e.g. Anthropite)", text: $newReplacement)
                    Button("Add") { add() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty
                            || newReplacement.isEmpty)
                }
            }

            Section("Active replacements") {
                if store.replacementEntries.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(store.replacementEntries.enumerated()), id: \.offset) { index, entry in
                        HStack {
                            Text(entry.pattern)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text(entry.replacement).bold()
                            Spacer()
                            Button {
                                store.replacementEntries.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(PaperTheme.paper)
    }

    private func add() {
        let pattern = newPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty, !newReplacement.isEmpty else { return }
        store.replacementEntries.append(
            .init(pattern: pattern, replacement: newReplacement)
        )
        newPattern = ""
        newReplacement = ""
    }
}

// MARK: - History

private struct HistorySettingsPane: View {
    @Bindable var store: SettingsStore
    let actions: SettingsActions

    @State private var entries: [TranscriptEntry] = []

    var body: some View {
        Form {
            Section {
                Toggle("Keep transcript history", isOn: $store.historyEnabled)
                Text("The last \(store.historyCap) transcripts are stored in a local database on this Mac — nothing syncs anywhere. Audio is never stored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recent transcripts") {
                if entries.isEmpty {
                    Text("Nothing yet. Dictate something!")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.text).lineLimit(2)
                                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.text, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy")
                        }
                    }
                    Button("Clear History", role: .destructive) {
                        actions.clearHistory()
                        entries = []
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(PaperTheme.paper)
        .onAppear { entries = actions.recentTranscripts() }
    }
}
