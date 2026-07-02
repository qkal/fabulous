import FabCore
import Foundation
import HotkeyEngine
import Observation

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
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onHotkeyChanged: (() -> Void)?
    @ObservationIgnored var onReplacementsChanged: (() -> Void)?
    @ObservationIgnored var onEngineChanged: (() -> Void)?

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
        replacementEntries = defaults.data(forKey: Keys.replacementEntries)
            .flatMap { try? JSONDecoder().decode([ReplacementDictionary.Entry].self, from: $0) }
            ?? []
    }
}
