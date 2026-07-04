import FabCore
import Foundation
import HotkeyEngine
import Observation
import TextInjector

/// User preferences, persisted to UserDefaults. Dumb storage: side effects
/// of a change (restarting the hotkey monitor, switching models) are the
/// AppController's job, hooked in via the change callbacks.
@MainActor
@Observable
final class SettingsStore {
    private enum Keys {
        static let hotkeySpec = "hotkeySpec.v2"
        static let selectedModelID = "selectedModelID"
        static let transcriptionEngine = "transcriptionEngine"
        static let inputDeviceUID = "inputDeviceUID"
        static let historyEnabled = "historyEnabled"
        static let soundCuesEnabled = "soundCuesEnabled"
        static let replacementEntries = "replacementEntries"
        static let theme = "theme"
        static let appearance = "appearance"
        static let llmCleanupEnabled = "llmCleanupEnabled"
        static let llmVocabulary = "llmVocabulary"
        static let appOverrideEntries = "appOverrideEntries"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onHotkeyChanged: (() -> Void)?
    @ObservationIgnored var onReplacementsChanged: (() -> Void)?
    @ObservationIgnored var onEngineChanged: (() -> Void)?
    @ObservationIgnored var onThemeChanged: (() -> Void)?
    @ObservationIgnored var onAppearanceChanged: (() -> Void)?
    @ObservationIgnored var onLLMCleanupChanged: (() -> Void)?
    @ObservationIgnored var onAppOverridesChanged: (() -> Void)?

    var hotkeySpec: HotkeySpec {
        didSet {
            guard hotkeySpec != oldValue else { return }
            if let data = try? JSONEncoder().encode(hotkeySpec) {
                defaults.set(data, forKey: Keys.hotkeySpec)
            }
            onHotkeyChanged?()
        }
    }

    /// The model the user chose. Which model is *loaded* is runtime state
    /// owned by the controller; this is only the preference.
    var selectedModelID: String {
        didSet { defaults.set(selectedModelID, forKey: Keys.selectedModelID) }
    }

    /// Which ASR engine transcribes. Whisper is the default; Apple Speech
    /// (macOS 26+) is the phase-4 experiment.
    var transcriptionEngine: TranscriptionEngineKind {
        didSet {
            guard transcriptionEngine != oldValue else { return }
            defaults.set(transcriptionEngine.rawValue, forKey: Keys.transcriptionEngine)
            onEngineChanged?()
        }
    }

    /// Core Audio device UID; nil = system default input.
    var inputDeviceUID: String? {
        didSet { defaults.set(inputDeviceUID, forKey: Keys.inputDeviceUID) }
    }

    var historyEnabled: Bool {
        didSet { defaults.set(historyEnabled, forKey: Keys.historyEnabled) }
    }

    var soundCuesEnabled: Bool {
        didSet { defaults.set(soundCuesEnabled, forKey: Keys.soundCuesEnabled) }
    }

    /// Visual theme for the whole app, including the dictation pill.
    var theme: ThemeKind {
        didSet {
            guard theme != oldValue else { return }
            defaults.set(theme.rawValue, forKey: Keys.theme)
            onThemeChanged?()
        }
    }

    /// System-appearance override (System / Light / Dark).
    var appearance: AppearanceKind {
        didSet {
            guard appearance != oldValue else { return }
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            onAppearanceChanged?()
        }
    }

    /// Custom text replacements, applied to every transcript in order.
    var replacementEntries: [ReplacementDictionary.Entry] {
        didSet {
            guard replacementEntries != oldValue else { return }
            if let data = try? JSONEncoder().encode(replacementEntries) {
                defaults.set(data, forKey: Keys.replacementEntries)
            }
            onReplacementsChanged?()
        }
    }

    /// Per-app injection overrides, layered over the built-in terminal
    /// defaults by the AppController — user wins on the same bundle ID.
    var appOverrideEntries: [AppOverride] {
        didSet {
            guard appOverrideEntries != oldValue else { return }
            if let data = try? JSONEncoder().encode(appOverrideEntries) {
                defaults.set(data, forKey: Keys.appOverrideEntries)
            } else {
                // In-memory overrides still apply this session, but the
                // disk copy is now stale — a relaunch reloads old entries.
                NSLog("fabulous: failed to persist app overrides")
            }
            onAppOverridesChanged?()
        }
    }

    /// LLM transcript cleanup (Apple Foundation Models). Off by default —
    /// it adds latency before injection.
    var llmCleanupEnabled: Bool {
        didSet {
            guard llmCleanupEnabled != oldValue else { return }
            defaults.set(llmCleanupEnabled, forKey: Keys.llmCleanupEnabled)
            onLLMCleanupChanged?()
        }
    }

    /// Names and jargon the cleanup model should prefer when audio is
    /// ambiguous. Feeds only the LLM prompt.
    var llmVocabulary: [String] {
        didSet {
            guard llmVocabulary != oldValue else { return }
            defaults.set(llmVocabulary, forKey: Keys.llmVocabulary)
            onLLMCleanupChanged?()
        }
    }

    let historyCap = 500

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkeySpec = defaults.data(forKey: Keys.hotkeySpec)
            .flatMap { try? JSONDecoder().decode(HotkeySpec.self, from: $0) }
            ?? .default
        selectedModelID = defaults.string(forKey: Keys.selectedModelID)
            ?? ModelCatalog.recommended.id
        transcriptionEngine = defaults.string(forKey: Keys.transcriptionEngine)
            .flatMap(TranscriptionEngineKind.init(rawValue:))
            ?? .whisper
        inputDeviceUID = defaults.string(forKey: Keys.inputDeviceUID)
        historyEnabled = defaults.object(forKey: Keys.historyEnabled) as? Bool ?? true
        soundCuesEnabled = defaults.object(forKey: Keys.soundCuesEnabled) as? Bool ?? true
        theme = defaults.string(forKey: Keys.theme)
            .flatMap(ThemeKind.init(rawValue:))
            ?? .paper
        appearance = defaults.string(forKey: Keys.appearance)
            .flatMap(AppearanceKind.init(rawValue:))
            ?? .system
        replacementEntries = defaults.data(forKey: Keys.replacementEntries)
            .flatMap { try? JSONDecoder().decode([ReplacementDictionary.Entry].self, from: $0) }
            ?? []
        appOverrideEntries = defaults.data(forKey: Keys.appOverrideEntries)
            .flatMap { try? JSONDecoder().decode([AppOverride].self, from: $0) }
            ?? []
        llmCleanupEnabled = defaults.bool(forKey: Keys.llmCleanupEnabled)
        llmVocabulary = defaults.stringArray(forKey: Keys.llmVocabulary) ?? []
    }
}
