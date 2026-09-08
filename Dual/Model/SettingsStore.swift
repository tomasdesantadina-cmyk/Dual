import DualCore
import Foundation

/// Persists CaptureSettings as JSON in UserDefaults.
struct SettingsStore {
    private let key = "com.intriq.dual.captureSettings.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> CaptureSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(CaptureSettings.self, from: data) else {
            return .default
        }
        return decoded.sanitized()
    }

    func save(_ settings: CaptureSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
