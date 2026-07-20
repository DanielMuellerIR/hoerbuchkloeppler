import Foundation

public class SettingsManager {
    public static let shared = SettingsManager()
    private let settingsURL: URL
    
    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let appDir = homeDir.appendingPathComponent(".Hoerbuchkloeppler")
        if !FileManager.default.fileExists(atPath: appDir.path) {
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        }
        self.settingsURL = appDir.appendingPathComponent("settings.json")
    }
    
    public func loadSettings() -> AudioSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONDecoder().decode(AudioSettings.self, from: data) else {
            // Default settings if file doesn't exist or is corrupted.
            // sampleRate MUSS mit dem deklarierten Default in AudioSettings (32 kHz)
            // übereinstimmen — sonst bekämen Erst-Nutzer beim ersten Start
            // versehentlich 48 kHz statt der bewussten 32-kHz-Voreinstellung.
            return AudioSettings(isMono: true, bitrate: "48k", sampleRate: 32000, maxDurationHours: nil, useParallelEncoding: true)
        }
        
        // Bewusste Design-Regel (docs/settings.md, „Parallel-Mode-Regel"):
        // Parallel-Encoding ist beim Start IMMER an. Der Toggle gilt nur für die
        // laufende Session; ein persistiertes "aus" überlebt den Neustart
        // absichtlich nicht.
        settings.useParallelEncoding = true
        return settings
    }
    
    public func saveSettings(_ settings: AudioSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }
}
