import Foundation
import Testing
@testable import HoerbuchkloepplerCore

@Suite("Einstellungspersistenz und Defaults")
struct SettingsPersistenceTests {
    @Test("Ungültige gespeicherte Werte fallen feldweise auf Defaults zurück")
    func invalidSettingsAreNormalized() {
        let invalid = AudioSettings(
            isMono: false,
            bitrate: "kaputt",
            sampleRate: 0,
            maxDurationHours: -4,
            useParallelEncoding: false,
            isVerbose: true
        )

        let normalized = invalid.normalized()

        #expect(!normalized.isMono)
        #expect(normalized.bitrate == "48k")
        #expect(normalized.sampleRate == 32_000)
        #expect(normalized.maxDurationHours == nil)
        #expect(!normalized.useParallelEncoding)
        #expect(normalized.isVerbose)
    }

    @Test("Bitrate und Abtastrate bleiben innerhalb der aac_at-Grenzen")
    func excessiveAudioSettingsAreRejected() {
        #expect(AudioSettings.isValidBitrate("320k"))
        #expect(AudioSettings.isValidBitrate("320000"))
        #expect(AudioSettings.isValidBitrate("8k"))
        #expect(!AudioSettings.isValidBitrate("1"))
        #expect(!AudioSettings.isValidBitrate("321k"))
        #expect(!AudioSettings.isValidBitrate("9000000k"))

        let normalized = AudioSettings(
            bitrate: "9000000k",
            sampleRate: 192_000
        ).normalized()
        #expect(normalized.bitrate == AudioSettings().bitrate)
        #expect(normalized.sampleRate == AudioSettings().sampleRate)
    }

    @Test("Laden nutzt AudioSettings als einzige Default-Quelle")
    func missingSettingsUseDefaults() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager(settingsURL: directory.appendingPathComponent("settings.json"))

        #expect(manager.loadSettings() == AudioSettings())
    }

    @Test("Ein fehlendes oder falsch typisiertes JSON-Feld verwirft keine gültigen Nachbarn")
    func malformedJSONFieldFallsBackIndividually() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        let json = """
        {
          "isMono": false,
          "bitrate": "64k",
          "sampleRate": "falsch",
          "maxDurationHours": 12,
          "useParallelEncoding": false
        }
        """
        try Data(json.utf8).write(to: settingsURL)
        let settings = SettingsManager(settingsURL: settingsURL).loadSettings()

        #expect(!settings.isMono)
        #expect(settings.bitrate == "64k")
        #expect(settings.sampleRate == 32_000)
        #expect(settings.maxDurationHours == 12)
        #expect(settings.useParallelEncoding)
        #expect(!settings.isVerbose)
    }

    @Test("Schreibfehler werden an den Aufrufer gemeldet")
    func saveErrorsAreReported() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pathBlockingDirectory = directory.appendingPathComponent("keine-directory")
        try Data("Datei".utf8).write(to: pathBlockingDirectory)
        let manager = SettingsManager(
            settingsURL: pathBlockingDirectory.appendingPathComponent("settings.json")
        )

        #expect(throws: (any Error).self) {
            try manager.saveSettings(AudioSettings())
        }
    }

    /// Bisher war `saveSettings` ausschließlich im Fehlerfall geprüft. Damit
    /// wäre unbemerkt geblieben, dass der Schreibpfad das Verzeichnis anlegt und
    /// vor dem Schreiben normalisiert.
    @Test("Speichern legt das Verzeichnis an, normalisiert und ist rundlauffähig")
    func saveCreatesDirectoryAndNormalizes() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory
            .appendingPathComponent("noch-nicht-da")
            .appendingPathComponent("settings.json")
        let manager = SettingsManager(settingsURL: target)

        var broken = AudioSettings()
        broken.bitrate = "999k"
        broken.sampleRate = 7
        try manager.saveSettings(broken)

        #expect(FileManager.default.fileExists(atPath: target.path))
        let written = try JSONDecoder().decode(
            AudioSettings.self,
            from: Data(contentsOf: target)
        )
        #expect(written.bitrate == AudioSettings().bitrate)
        #expect(written.sampleRate == AudioSettings().sampleRate)
        #expect(manager.loadSettings() == written)
    }
}
