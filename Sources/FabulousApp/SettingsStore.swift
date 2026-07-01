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
        static let inputDeviceUID = "inputDeviceUID"
        static let historyEnabled = "historyEnabled"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onHotkeyChanged: (() -> Void)?

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

    /// Core Audio device UID; nil = system default input.
    var inputDeviceUID: String? {
        didSet { defaults.set(inputDeviceUID, forKey: Keys.inputDeviceUID) }
    }

    var historyEnabled: Bool {
        didSet { defaults.set(historyEnabled, forKey: Keys.historyEnabled) }
    }

    let historyCap = 500

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkeySpec = defaults.data(forKey: Keys.hotkeySpec)
            .flatMap { try? JSONDecoder().decode(HotkeySpec.self, from: $0) }
            ?? .default
        selectedModelID = defaults.string(forKey: Keys.selectedModelID)
            ?? ModelCatalog.recommended.id
        inputDeviceUID = defaults.string(forKey: Keys.inputDeviceUID)
        historyEnabled = defaults.object(forKey: Keys.historyEnabled) as? Bool ?? true
    }
}
