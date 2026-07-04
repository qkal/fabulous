import AppKit
import AudioCapture
import FabCore
import HistoryStore
import HotkeyEngine
import PostProcessing
import SwiftUI
import TextInjector
import UniformTypeIdentifiers

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
    case general, models, replacements, apps, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .models: "Models"
        case .replacements: "Replacements"
        case .apps: "Apps"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .models: "brain"
        case .replacements: "character.cursor.ibeam"
        case .apps: "app"
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

    private var theme: Theme { Theme.current(store.theme) }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .scrollContentBackground(.hidden)
            .background(theme.paper)
        } detail: {
            detailView
                .navigationTitle(section.title)
        }
        .background(theme.paper)
        .environment(\.theme, theme)
        .tint(theme.accent)
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
        case .apps:
            AppsSettingsPane(store: store)
        case .history:
            HistorySettingsPane(store: store, actions: actions)
        }
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @Bindable var store: SettingsStore
    let actions: SettingsActions

    @Environment(\.theme) private var theme

    @State private var capturing = false
    @State private var captureSession = KeyCaptureSession()
    @State private var devices: [CaptureDevice] = []
    @State private var launchAtLogin = false
    @State private var launchAtLoginError: String?
    @State private var newVocabularyTerm = ""

    private var cleanupAvailability: PostProcessingAvailability {
        PostProcessingAvailability.current
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $store.theme) {
                    ForEach(ThemeKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.radioGroup)
                Picker("Appearance", selection: $store.appearance) {
                    ForEach(AppearanceKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Glass is always dark.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

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

            Section("Transcription") {
                Picker("Engine", selection: $store.transcriptionEngine) {
                    ForEach(availableEngines, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Whisper models are picked in the Models tab. Apple Speech uses the system's on-device recognizer. Parakeet downloads its models on first use — faster, but experimental.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Clean up with Apple Intelligence") {
                Toggle("Clean up transcripts", isOn: $store.llmCleanupEnabled)
                    .disabled(cleanupAvailability != .available && !store.llmCleanupEnabled)
                if let explanation = cleanupAvailability.explanation {
                    Text(explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Removes filler words, fixes punctuation, and understands “new paragraph”, “scratch that”, and “quote … unquote”. Runs on this Mac — nothing leaves it. Adds a moment before text appears.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if store.llmCleanupEnabled {
                    HStack {
                        TextField("Add a name or term…", text: $newVocabularyTerm)
                            .onSubmit(addVocabularyTerm)
                        Button("Add", action: addVocabularyTerm)
                            .disabled(newVocabularyTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    // Terms are deduplicated on add, so the string is a
                    // stable identity — unlike offsets, which shift on
                    // removal and confuse the diff.
                    ForEach(store.llmVocabulary, id: \.self) { term in
                        HStack {
                            Text(term)
                            Spacer()
                            Button {
                                store.llmVocabulary.removeAll { $0 == term }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Text("Spellings the cleanup pass should prefer — names, jargon, product terms.")
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
        .background(theme.paper)
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

    private func addVocabularyTerm() {
        let term = newVocabularyTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !store.llmVocabulary.contains(term) else { return }
        store.llmVocabulary.append(term)
        newVocabularyTerm = ""
    }

    /// Apple Speech requires the macOS 26 SpeechAnalyzer; the other
    /// engines run on this package's macOS 14 floor.
    private var availableEngines: [TranscriptionEngineKind] {
        TranscriptionEngineKind.allCases.filter { kind in
            guard kind == .appleSpeech else { return true }
            if #available(macOS 26.0, *) { return true }
            return false
        }
    }
}

// MARK: - Models

private struct ModelsSettingsPane: View {
    @Bindable var store: SettingsStore
    let models: ModelListModel
    let connectivity: ConnectivityMonitor
    let actions: SettingsActions

    @Environment(\.theme) private var theme

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
                Text("Models run entirely on this Mac. Downloads come from Hugging Face (argmaxinc/whisperkit-coreml for Whisper, FluidInference for Parakeet) into ~/Library/Application Support/fabulous/models/.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.paper)
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

    @Environment(\.theme) private var theme

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
        .background(theme.paper)
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

// MARK: - Apps

/// Per-app injection overrides: which strategy the chain starts at for a
/// given frontmost app. Built-in terminal defaults are shown greyed; a
/// user entry on the same bundle ID shadows the built-in (that's also how
/// a built-in is "undone" — shadow it with Accessibility insert).
private struct AppsSettingsPane: View {
    @Bindable var store: SettingsStore

    @Environment(\.theme) private var theme

    /// One list row — built-in default or user override. A user entry on
    /// a built-in bundle ID replaces the built-in row.
    private struct Row: Identifiable {
        let bundleID: String
        let displayName: String
        let strategy: InjectionStrategy
        let isUserEntry: Bool
        var id: String { bundleID }
    }

    private var rows: [Row] {
        var byID: [String: Row] = [:]
        for (bundleID, strategy) in StrategySelector.defaultOverrides {
            byID[bundleID] = Row(
                bundleID: bundleID,
                displayName: StrategySelector.builtInDisplayNames[bundleID] ?? bundleID,
                strategy: strategy,
                isUserEntry: false
            )
        }
        for entry in store.appOverrideEntries {
            byID[entry.bundleID] = Row(
                bundleID: entry.bundleID,
                displayName: entry.displayName,
                strategy: entry.strategy,
                isUserEntry: true
            )
        }
        return byID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending
        }
    }

    var body: some View {
        Form {
            Section {
                Text("Choose which injection method fabulous tries first in a specific app. If that method fails, the usual fallbacks still apply. Built-in rows cover terminals that mishandle direct insertion; change their method to override them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Overrides") {
                ForEach(rows) { row in
                    rowView(row)
                }
                Button {
                    addApp()
                } label: {
                    Label("Add App…", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.paper)
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: icon(for: row.bundleID))
                .resizable()
                .frame(width: 20, height: 20)
            Text(row.displayName)
                .foregroundStyle(row.isUserEntry ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            if !row.isUserEntry {
                Text("built-in")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.accent.opacity(0.15)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: strategyBinding(for: row)) {
                ForEach(InjectionStrategy.allCases, id: \.self) { strategy in
                    Text(displayName(of: strategy)).tag(strategy)
                }
            }
            .labelsHidden()
            .fixedSize()
            Button {
                store.appOverrideEntries.removeAll { $0.bundleID == row.bundleID }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!row.isUserEntry)
            .help(row.isUserEntry
                ? "Remove override"
                : "Built-in — change its method to shadow it")
        }
    }

    /// Any picker change writes a user entry, even one equal to the
    /// built-in's value — one uniform rule, and the result is deletable.
    private func strategyBinding(for row: Row) -> Binding<InjectionStrategy> {
        Binding(
            get: { row.strategy },
            set: { newValue in
                if let index = store.appOverrideEntries.firstIndex(
                    where: { $0.bundleID == row.bundleID }
                ) {
                    store.appOverrideEntries[index].strategy = newValue
                } else {
                    store.appOverrideEntries.append(.init(
                        bundleID: row.bundleID,
                        displayName: row.displayName,
                        strategy: newValue
                    ))
                }
            }
        )
    }

    private func displayName(of strategy: InjectionStrategy) -> String {
        switch strategy {
        case .axInsert: "Accessibility insert"
        case .paste: "Paste"
        case .keystrokes: "Keystrokes"
        }
    }

    /// LaunchServices icon lookups can hit disk, and SwiftUI re-evaluates
    /// body (all rows) on every store edit — cache per bundle ID.
    @MainActor private static var iconCache: [String: NSImage] = [:]

    @MainActor
    private func icon(for bundleID: String) -> NSImage {
        if let cached = Self.iconCache[bundleID] { return cached }
        let icon: NSImage =
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.icon(forFile: url.path)
            } else {
                NSWorkspace.shared.icon(for: .applicationBundle)
            }
        Self.iconCache[bundleID] = icon
        return icon
    }

    private func addApp() {
        let panel = NSOpenPanel()
        // Starting point only — system apps live in /System/Applications,
        // so the user can browse anywhere.
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an app to set an injection method for"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier
        else { return }  // bundle without an identifier: ignore (spec)

        // Already listed (user row or built-in)? The row is on screen —
        // no duplicate is created.
        guard !rows.contains(where: { $0.bundleID == bundleID }) else { return }

        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        // Paste: the most common reason to override at all.
        store.appOverrideEntries.append(.init(
            bundleID: bundleID, displayName: name, strategy: .paste
        ))
    }
}

// MARK: - History

private struct HistorySettingsPane: View {
    @Bindable var store: SettingsStore
    let actions: SettingsActions

    @Environment(\.theme) private var theme

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
                                if let raw = entry.rawText {
                                    Text("Original: \(raw)")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
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
        .background(theme.paper)
        .onAppear { entries = actions.recentTranscripts() }
    }
}
