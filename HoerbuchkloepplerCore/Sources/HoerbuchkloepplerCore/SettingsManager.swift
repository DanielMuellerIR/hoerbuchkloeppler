import Foundation

/// Unveränderlicher Zugriffspunkt auf genau eine Einstellungsdatei. Da der
/// Manager nach der Initialisierung keinen eigenen Zustand mehr ändert, kann er
/// gefahrlos aus verschiedenen Concurrency-Domänen verwendet werden.
public final class SettingsManager: Sendable {
    public static let shared = SettingsManager()
    private let settingsURL: URL
    
    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let appDir = homeDir.appendingPathComponent(".Hoerbuchkloeppler")
        self.settingsURL = appDir.appendingPathComponent("settings.json")
    }

    /// Separater Pfad nur für Tests; die öffentliche App verwendet `shared`.
    init(settingsURL: URL) {
        self.settingsURL = settingsURL
    }
    
    public func loadSettings() -> AudioSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONDecoder().decode(AudioSettings.self, from: data) else {
            return AudioSettings()
        }
        settings = settings.normalized()

        // Bewusste Design-Regel (docs/settings.md, „Parallel-Mode-Regel"):
        // Parallel-Encoding ist beim Start IMMER an. Der Toggle gilt nur für die
        // laufende Session; ein persistiertes "aus" überlebt den Neustart
        // absichtlich nicht.
        settings.useParallelEncoding = true
        return settings
    }
    
    public func saveSettings(_ settings: AudioSettings) throws {
        let directory = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(settings.normalized())
        try data.write(to: settingsURL, options: .atomic)
    }
}
