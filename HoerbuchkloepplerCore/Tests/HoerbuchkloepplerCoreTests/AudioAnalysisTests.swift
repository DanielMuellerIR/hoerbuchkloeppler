import Foundation
import Testing
@testable import HoerbuchkloepplerCore
import AVFoundation

@Suite("Asynchrone AVFoundation-Analyse")
@MainActor
struct AsyncAVFoundationTests {
    @Test("AudioFile lädt Dauer und Fallback-Titel asynchron aus einer echten WAV-Datei")
    func loadsAudioPropertiesAsynchronously() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Kapitel Eins.wav")

        // Ein echtes kurzes Audio-Fixture verhindert, dass der Test nur unsere
        // Fehler-Fallbacks bestätigt. AVAudioFile erzeugt einen gültigen Header
        // und 0,25 Sekunden stille PCM-Samples.
        do {
            let format = try #require(
                AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)
            )
            let buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_000)
            )
            buffer.frameLength = 2_000
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let audio = await AudioFile(url: url)
        let artwork = await AudioFile.extractEmbeddedArtwork(from: url)

        #expect(abs(audio.duration - 0.25) < 0.02)
        #expect(audio.chapterTitle == "Kapitel Eins")
        #expect(artwork == nil)
    }

    @Test("Ordner mit Audio-Endung werden beim rekursiven Scan nicht importiert")
    func scanIgnoresDirectoriesWithAudioExtension() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Kein Kapitel.mp3"),
            withIntermediateDirectories: false
        )
        let session = ConversionSession(settings: AudioSettings())

        let scanned = await session.scanFolder(directory)

        #expect(scanned.audioFiles.isEmpty)
    }

    @Test("Ein Symlink auf eine reguläre Audiodatei wird importiert")
    func scanImportsAudioFileSymlink() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceDirectory = directory.appendingPathComponent("Quelle")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        let target = directory.appendingPathComponent("Original.wav")
        let link = sourceDirectory.appendingPathComponent("Kapitel per Link.wav")

        // Den Writer vor dem Import freigeben; erst dann ist der WAV-Header
        // vollständig geschrieben und AVFoundation kann die Dauer lesen.
        do {
            let format = try #require(
                AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)
            )
            let buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_000)
            )
            buffer.frameLength = 2_000
            let file = try AVAudioFile(forWriting: target, settings: format.settings)
            try file.write(from: buffer)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let session = ConversionSession(settings: AudioSettings())
        let scanned = await session.scanFolder(sourceDirectory)
        let audioFile = try #require(scanned.audioFiles.first)

        #expect(scanned.audioFiles.count == 1)
        #expect(audioFile.url == target.resolvingSymlinksInPath())
        #expect(abs(audioFile.duration - 0.25) < 0.02)
    }

    @Test("Der rekursive Scan prüft den Abbruch auch direkt nach nextObject")
    func recursiveScanStopsDuringEnumeration() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 1...10 {
            try Data("Datei \(index)".utf8).write(
                to: directory.appendingPathComponent("\(index).txt")
            )
        }
        var cancellationChecks = 0

        let files = ConversionSession.recursiveFileURLs(in: directory) {
            cancellationChecks += 1
            // 1: vor dem Enumerator, 2: vor dem ersten nextObject,
            // 3: direkt danach. Das erste Ergebnis darf dann nicht mehr in die
            // vollständig materialisierte Dateiliste gelangen.
            return cancellationChecks >= 3
        }

        #expect(files.isEmpty)
        #expect(cancellationChecks == 3)
    }

    @Test("Ein Lesefehler verwirft das vollständige Scan-Teilergebnis")
    func scanFailsClosedAfterTraversalError() throws {
        let directory = try makeTestDirectory()
        let blocked = directory.appendingPathComponent("zz-nicht-lesbar")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: blocked.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        try writeSilentWAV(to: directory.appendingPathComponent("01-gueltig.wav"))
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: blocked.path
        )

        let discovered = ConversionSession.discoverFileURLs(in: directory)

        #expect(discovered.files.isEmpty)
        #expect(discovered.failureDescription?.contains("zz-nicht-lesbar") == true)
    }
}

@Suite("AudioFile – sanitizeDuration")
struct SanitizeDurationTests {

    @Test("NaN wird zu 0")
    func nanBecomesZero() {
        // CMTimeGetSeconds liefert bei unlesbaren Dateien NaN. Ungeklemmt würden
        // spätere Int(NaN)-Casts crashen.
        #expect(AudioFile.sanitizeDuration(.nan) == 0)
    }

    @Test("Unendlich wird zu 0")
    func infinityBecomesZero() {
        #expect(AudioFile.sanitizeDuration(.infinity) == 0)
        #expect(AudioFile.sanitizeDuration(-.infinity) == 0)
    }

    @Test("Negative Dauer wird zu 0")
    func negativeBecomesZero() {
        #expect(AudioFile.sanitizeDuration(-5) == 0)
    }

    @Test("Gültige Dauer bleibt unverändert")
    func validUnchanged() {
        #expect(AudioFile.sanitizeDuration(42.5) == 42.5)
        #expect(AudioFile.sanitizeDuration(0) == 0)
    }

    @Test("Initializer klemmt die Dauer an der Quelle")
    func initSanitizes() {
        let file = AudioFile(url: URL(fileURLWithPath: "/tmp/x.mp3"), startTime: .nan, duration: .nan, chapterTitle: "x")
        #expect(file.duration == 0)
        #expect(file.startTime == 0)
    }
}
