import Foundation
import Testing
import AVFoundation
@testable import HoerbuchkloepplerCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("HoerbuchkloepplerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeExecutable(_ url: URL, contents: String) throws {
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func writeSilentWAV(to url: URL, duration: TimeInterval = 0.25) throws {
    let sampleRate = 8_000.0
    let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
    )
    let frameCount = AVAudioFrameCount(sampleRate * duration)
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
    )
    buffer.frameLength = frameCount
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

private final class ThreadSafeLogProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

/// Deterministische Schranke für Race-Tests: Der Hintergrund-Thread meldet,
/// dass er den kritischen Abschnitt erreicht hat, und wartet auf die Freigabe.
private final class BlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = false
    private var released = false

    func blockUntilReleased() {
        condition.lock()
        blocked = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilBlocked() {
        condition.lock()
        while !blocked {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private actor PreparationCancellationProbe {
    private var started = false
    private var observedCancellation = false

    func markStarted() { started = true }
    func markFinished(cancelled: Bool) { observedCancellation = cancelled }
    func snapshot() -> (started: Bool, observedCancellation: Bool) {
        (started, observedCancellation)
    }
}

@Suite("Swift 6 – asynchrone AVFoundation-Analyse")
@MainActor
struct AsyncAVFoundationTests {
    @Test("AudioFile lädt Dauer und Fallback-Titel asynchron aus einer echten WAV-Datei")
    func loadsAudioPropertiesAsynchronously() async throws {
        let directory = try temporaryDirectory()
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
        let directory = try temporaryDirectory()
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
        let directory = try temporaryDirectory()
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
        let directory = try temporaryDirectory()
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
        let directory = try temporaryDirectory()
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

@Suite("Review-Fixes – Ausgabeplan und atomare Übernahme")
struct OutputSafetyTests {
    @Test("Der zentrale Plan nennt alle tatsächlichen Split-Ziele")
    func planContainsAllSplitOutputs() {
        let files = [1.0, 1.0, 1.0].map {
            AudioFile(url: URL(fileURLWithPath: "/tmp/source.mp3"), startTime: 0, duration: $0 * 3600, chapterTitle: "Kapitel")
        }
        let plan = FFmpegWrapper.makeConversionPlan(
            files: files,
            outputURL: URL(fileURLWithPath: "/tmp/Buch.m4b"),
            maxDurationHours: 2
        )
        #expect(plan.groups.map(\.count) == [2, 1])
        #expect(plan.outputURLs.map(\.lastPathComponent) == ["Buch-01.m4b", "Buch-02.m4b"])
    }

    @Test("Die bestehende Ausgabe bleibt bis zum atomaren Commit erhalten")
    func atomicCommitReplacesOnlyAtCommit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = FFmpegWrapper.stagingOutputURL(for: final, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        try Data("alt".utf8).write(to: final)
        let expected = FFmpegWrapper.captureSnapshot(of: final)
        try Data("neu".utf8).write(to: staged)

        #expect(try String(contentsOf: final, encoding: .utf8) == "alt")
        try FFmpegWrapper.commitStagedOutput(
            staged,
            to: final,
            expectedDestination: expected
        )
        #expect(try String(contentsOf: final, encoding: .utf8) == "neu")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test("Eine leere Partial-Datei ersetzt keine bestehende Ausgabe")
    func emptyStagingDoesNotReplace() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = directory.appendingPathComponent(".Buch.partial.m4b")
        try Data("behalten".utf8).write(to: final)
        let expected = FFmpegWrapper.captureSnapshot(of: final)
        try Data().write(to: staged)

        #expect(throws: (any Error).self) {
            try FFmpegWrapper.commitStagedOutput(
                staged,
                to: final,
                expectedDestination: expected
            )
        }
        #expect(try String(contentsOf: final, encoding: .utf8) == "behalten")
    }

    @Test("Staging-Dateien tragen die Besitzer-PID als Laufmarke im Namen")
    func stagingURLCarriesOwnerPID() {
        let final = URL(fileURLWithPath: "/tmp/Buch.m4b")
        let staged = FFmpegWrapper.stagingOutputURL(for: final)
        #expect(FFmpegWrapper.stagedOutputOwnerPID(staged) == ProcessInfo.processInfo.processIdentifier)
    }

    @Test("Staging-Namen bleiben auch bei langen UTF-8-Titeln unter NAME_MAX")
    func stagingURLTruncatesLongBasenameByUTF8Bytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 125 Umlaute = 250 UTF-8-Bytes; der finale Name passt gerade noch,
        // der ungekürzte Staging-Zusatz dagegen nicht.
        let final = directory.appendingPathComponent(String(repeating: "ä", count: 125) + ".m4b")
        let staged = FFmpegWrapper.stagingOutputURL(for: final, ownerPID: 987_654)
        #expect(staged.lastPathComponent.utf8.count <= Int(NAME_MAX))

        try FFmpegWrapper.createOwnedStagingOutput(staged, ownerPID: 987_654)
        try Data("unvollständig".utf8).write(to: staged)
        FFmpegWrapper.removeOrphanedStagedOutputs(for: final)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test("Altformat-Partials ohne PID-Marke liefern keine Besitzer-PID")
    func legacyStagingNameHasNoOwner() {
        // Alte Namen waren `.partial-<uuid>`; eine rein numerische erste
        // UUID-Gruppe darf nicht als PID fehlinterpretiert werden.
        let legacy = URL(fileURLWithPath: "/tmp/.Buch.partial-12345678-1234-1234-1234-123456789012.m4b")
        #expect(FFmpegWrapper.stagedOutputOwnerPID(legacy) == nil)
        #expect(FFmpegWrapper.stagedOutputOwnerPID(URL(fileURLWithPath: "/tmp/Buch.m4b")) == nil)
    }

    @Test("Verwaiste Partial-Dateien toter Prozesse werden vor dem nächsten Lauf entfernt")
    func removesOrphanedStagedOutputs() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        // Oberhalb von macOS' PID_MAX (99999) — sicher kein lebender Prozess.
        let orphan = FFmpegWrapper.stagingOutputURL(for: final, ownerPID: 987_654)
        let alive = FFmpegWrapper.stagingOutputURL(for: final)
        let legacy = directory.appendingPathComponent(".Buch.partial-\(UUID().uuidString).m4b")
        let otherTarget = directory.appendingPathComponent(".Anderes.partial-987654-\(UUID().uuidString).m4b")
        try FFmpegWrapper.createOwnedStagingOutput(orphan, ownerPID: 987_654)
        try FFmpegWrapper.createOwnedStagingOutput(alive)
        try Data("unvollständig".utf8).write(to: orphan)
        try Data("unvollständig".utf8).write(to: alive)
        for url in [legacy, otherTarget] {
            try Data("unvollständig".utf8).write(to: url)
        }

        FFmpegWrapper.removeOrphanedStagedOutputs(for: final)

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        // Der eigene (lebende) Prozess, Altformat-Namen und fremde Ziele
        // bleiben unangetastet.
        #expect(FileManager.default.fileExists(atPath: alive.path))
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: otherTarget.path))
    }

    @Test("Case-insensitive Volumes entfernen abweichende Schreibweisen")
    func caseInsensitiveVolumeRemovesDifferentCasing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let uppercaseFinal = directory.appendingPathComponent("BUCH.M4B")
        let lowercaseFinal = directory.appendingPathComponent("buch.m4b")
        let orphan = FFmpegWrapper.stagingOutputURL(for: uppercaseFinal, ownerPID: 987_654)
        try FFmpegWrapper.createOwnedStagingOutput(orphan, ownerPID: 987_654)
        try Data("unvollständig".utf8).write(to: orphan)

        FFmpegWrapper.removeOrphanedStagedOutputs(
            for: lowercaseFinal,
            caseSensitiveNames: false
        )

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test("Case-sensitive Volumes behalten abweichende Schreibweisen")
    func caseSensitiveVolumeKeepsDifferentCasing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let uppercaseFinal = directory.appendingPathComponent("BUCH.M4B")
        let lowercaseFinal = directory.appendingPathComponent("buch.m4b")
        let orphan = FFmpegWrapper.stagingOutputURL(for: uppercaseFinal, ownerPID: 987_654)
        try FFmpegWrapper.createOwnedStagingOutput(orphan, ownerPID: 987_654)
        try Data("unvollständig".utf8).write(to: orphan)

        FFmpegWrapper.removeOrphanedStagedOutputs(
            for: lowercaseFinal,
            caseSensitiveNames: true
        )

        #expect(FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test("Ein Ziel mit `.partial-` im eigenen Namen wird trotzdem aufgeräumt")
    func handlesTargetNameContainingMarker() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // `sanitizeFilename` lässt Punkte und Bindestriche durch, ein solcher
        // Titel ist also über `--output` und den GUI-Speicherdialog erreichbar.
        let final = directory.appendingPathComponent("Mein.partial-Buch.m4b")
        // Oberhalb von macOS' PID_MAX (99999) — sicher kein lebender Prozess.
        let orphan = FFmpegWrapper.stagingOutputURL(for: final, ownerPID: 987_654)
        let alive = FFmpegWrapper.stagingOutputURL(for: final)

        // Erzeugen und Parsen müssen zusammenpassen: Nur der letzte Marker zählt.
        #expect(orphan.lastPathComponent.hasPrefix(".Mein.partial-Buch.partial-"))
        #expect(FFmpegWrapper.stagedOutputOwnerPID(orphan) == 987_654)
        #expect(FFmpegWrapper.stagedOutputOwnerPID(alive) == ProcessInfo.processInfo.processIdentifier)

        try FFmpegWrapper.createOwnedStagingOutput(orphan, ownerPID: 987_654)
        try FFmpegWrapper.createOwnedStagingOutput(alive)
        for url in [orphan, alive] {
            try Data("unvollständig".utf8).write(to: url)
        }

        FFmpegWrapper.removeOrphanedStagedOutputs(for: final)

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: alive.path))
    }

    @Test("Ein gleichnamiger Ordner wird nicht rekursiv gelöscht")
    func doesNotRemoveDirectoriesMatchingStagingName() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        // Gleicher Name wie eine verwaiste Partial-Datei, aber ein Ordner mit
        // Inhalt — der darf auf keinen Fall mitsamt Inhalt verschwinden.
        let decoyDirectory = FFmpegWrapper.stagingOutputURL(for: final, ownerPID: 987_654)
        try FileManager.default.createDirectory(at: decoyDirectory, withIntermediateDirectories: true)
        let payload = decoyDirectory.appendingPathComponent("wichtig.txt")
        try Data("nicht anfassen".utf8).write(to: payload)

        let logs = ThreadSafeLogProbe()
        FFmpegWrapper.removeOrphanedStagedOutputs(for: final, log: logs.append)

        #expect(FileManager.default.fileExists(atPath: decoyDirectory.path))
        #expect(FileManager.default.fileExists(atPath: payload.path))
        #expect(logs.snapshot().contains { $0.contains("Unmarkierter Staging-Eintrag") })
    }

    @Test("Ein nach der Typprüfung eingesetzter Ordner wird nicht rekursiv gelöscht")
    func doesNotRemoveDirectoryInsertedBeforeUnlink() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let orphan = FFmpegWrapper.stagingOutputURL(for: final, ownerPID: 987_654)
        try FFmpegWrapper.createOwnedStagingOutput(orphan, ownerPID: 987_654)
        try Data("unvollständig".utf8).write(to: orphan)
        var replacementError: (any Error)?
        let payload = orphan.appendingPathComponent("wichtig.txt")

        FFmpegWrapper.removeOrphanedStagedOutputs(for: final, beforeUnlink: { checkedURL in
            do {
                try FileManager.default.removeItem(at: checkedURL)
                try FileManager.default.createDirectory(
                    at: checkedURL,
                    withIntermediateDirectories: false
                )
                try Data("nicht anfassen".utf8).write(to: payload)
            } catch {
                replacementError = error
            }
        })

        #expect(replacementError == nil)
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: payload.path))
    }

    @Test("Verwaiste Partial-Dateien einer anderen Zielendung bleiben erhalten")
    func doesNotRemoveStagingFilesForDifferentExtension() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audiobook = directory.appendingPathComponent("Buch.m4b")
        let textFile = directory.appendingPathComponent("Buch.txt")
        let decoy = FFmpegWrapper.stagingOutputURL(for: textFile, ownerPID: 987_654)
        try Data("nicht anfassen".utf8).write(to: decoy)

        FFmpegWrapper.removeOrphanedStagedOutputs(for: audiobook)

        #expect(FileManager.default.fileExists(atPath: decoy.path))
    }

    @Test("Fortschritt mehrerer Split-Gruppen bleibt monoton")
    func splitProgressIsMonotonic() {
        let values = [
            FFmpegWrapper.mappedProgress(base: 0, weight: 0.5, phaseProgress: 0),
            FFmpegWrapper.mappedProgress(base: 0, weight: 0.5, phaseProgress: 0.5),
            FFmpegWrapper.mappedProgress(base: 0, weight: 0.5, phaseProgress: 1),
            FFmpegWrapper.mappedProgress(base: 0.5, weight: 0.5, phaseProgress: 0),
            FFmpegWrapper.mappedProgress(base: 0.5, weight: 0.5, phaseProgress: 1)
        ]

        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values.last == 1)
    }

    @Test("Sehr kurze Zeiten werden ohne Exponentialschreibweise an ffmpeg übergeben")
    func tinyTimesUseFixedDecimalArguments() {
        let file = AudioFile(
            url: URL(fileURLWithPath: "/tmp/kurz.m4b"),
            startTime: 0.00001,
            duration: 0.00002,
            chapterTitle: "Kurz"
        )
        let args = FFmpegWrapper.getArgsForStandardSlicing(
            file: file,
            url: URL(fileURLWithPath: "/tmp/kurz.wav"),
            settings: AudioSettings()
        )

        #expect(args[args.firstIndex(of: "-ss")! + 1] == "0.000010")
        #expect(args[args.firstIndex(of: "-t")! + 1] == "0.000020")
        #expect(!args.contains { $0.lowercased().contains("e-") })
    }

    @Test("Der finale ffmpeg-Fehler enthält dessen stderr-Ursache")
    @MainActor
    func finalProcessFailureIncludesStderr() async {
        let session = ConversionSession(settings: AudioSettings())
        let context = session.beginConversionRun()

        let succeeded = FFmpegWrapper.runFinalProcess(
            args: ["-nostdin", "-definitely-not-an-option"],
            session: session,
            context: context,
            progressBase: 0,
            progressWeight: 1,
            phaseDuration: 1,
            logMessage: "Testlauf",
            pacmanTitle: "Test"
        )
        for _ in 0..<10 where !session.eventLogs.contains(where: {
            $0.message.contains("Exit-Code")
        }) {
            await Task.yield()
        }

        #expect(!succeeded)
        let failure = session.eventLogs.first { $0.message.contains("Exit-Code") }?.message
        #expect(failure?.contains("Unrecognized option") == true)
    }
}

@Suite("Review-Fixes – Tool-Auflösung")
struct ToolResolutionTests {
    @Test("Nicht ausführbares Bundle-Tool verdeckt PATH nicht")
    func skipsBrokenBundledCandidate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundled = directory.appendingPathComponent("bundled-ffmpeg")
        let pathDirectory = directory.appendingPathComponent("path")
        try FileManager.default.createDirectory(at: pathDirectory, withIntermediateDirectories: true)
        let pathTool = pathDirectory.appendingPathComponent("ffmpeg")
        try "kaputt".write(to: bundled, atomically: true, encoding: .utf8)
        try makeExecutable(pathTool, contents: "#!/bin/sh\nexit 0\n")

        let resolved = FFmpegWrapper.resolveBinaryURL(
            name: "ffmpeg",
            bundledURL: bundled,
            pathEnvironment: pathDirectory.path,
            fallbackPaths: []
        )
        #expect(resolved == pathTool)
    }

    @Test("Verzeichnisse gelten nicht als ausführbare Tools")
    func rejectsDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!FFmpegWrapper.isUsableExecutable(directory))
    }

    @Test("Symlink auf ein ausführbares Ziel gilt als brauchbares Tool (Homebrew-Fall)")
    func acceptsSymlinkToExecutable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Nachbau des Homebrew-Layouts: bin/ffmpeg -> ../Cellar/ffmpeg/ffmpeg
        let cellar = directory.appendingPathComponent("Cellar")
        let binDirectory = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: cellar, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let target = cellar.appendingPathComponent("ffmpeg")
        try makeExecutable(target, contents: "#!/bin/sh\nexit 0\n")
        let link = binDirectory.appendingPathComponent("ffmpeg")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "../Cellar/ffmpeg"
        )

        #expect(FFmpegWrapper.isUsableExecutable(link))
        // Die PATH-Auflösung akzeptiert den Kandidaten, friert aber das geprüfte
        // Ziel ein; eine spätere Umlenkung des Symlinks darf nichts ändern.
        let resolved = FFmpegWrapper.resolveBinaryURL(
            name: "ffmpeg",
            bundledURL: nil,
            pathEnvironment: binDirectory.path,
            fallbackPaths: []
        )
        #expect(resolved == target)
    }

    @Test("Hängender Symlink ohne Ziel bleibt unbrauchbar")
    func rejectsDanglingSymlink() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("ffmpeg")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "gibt-es-nicht"
        )

        #expect(!FFmpegWrapper.isUsableExecutable(link))
    }

    @Test("Version gilt nur bei Exit 0 und nichtleerer Ausgabe")
    func validatesVersionProcess() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appendingPathComponent("good")
        let bad = directory.appendingPathComponent("bad")
        try makeExecutable(good, contents: "#!/bin/sh\necho 'ffmpeg version 7.1'\n")
        try makeExecutable(bad, contents: "#!/bin/sh\necho 'ffmpeg version kaputt'\nexit 3\n")
        #expect(FFmpegWrapper.toolVersion(at: good, name: "ffmpeg") == "7.1")
        #expect(FFmpegWrapper.toolVersion(at: bad, name: "ffmpeg") == nil)
    }

    @Test("Große Versionsausgabe blockiert nicht am Pipe-Puffer")
    func drainsLargeVersionOutputBeforeWaiting() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = directory.appendingPathComponent("large-output")
        try makeExecutable(
            tool,
            contents: """
            #!/bin/sh
            /usr/bin/yes x | /usr/bin/head -c 200000
            printf '\nffmpeg version 7.1\n'
            """
        )

        #expect(FFmpegWrapper.toolVersion(at: tool, name: "ffmpeg") == "7.1")
    }
}

@Suite("Review-Fixes – laufbezogener Abbruch")
@MainActor
struct CancellationIsolationTests {
    @Test("Ein vor dem Ordnerscan abgebrochener Lauf bleibt als Abbruch erkennbar")
    func cancelledFolderScanIsMarkedAsCancelled() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = ConversionSession(settings: AudioSettings())

        session.beginPreparation()
        #expect(session.cancelPreparation())

        let scanned = await session.scanFolder(directory)

        #expect(scanned.wasCancelled)
        #expect(scanned.audioFiles.isEmpty)
        #expect(scanned.imageURLs.isEmpty)
    }

    @Test("Vorbereitungsabbruch cancelt den registrierten Swift-Task")
    func preparationCancellationReachesTask() async throws {
        let session = ConversionSession(settings: AudioSettings())
        let probe = PreparationCancellationProbe()
        session.beginPreparation()
        let work = Task {
            await session.runPreparationTask {
                await probe.markStarted()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    // CancellationError ist hier das erwartete Ende.
                }
                await probe.markFinished(cancelled: Task.isCancelled)
            }
        }

        var state = await probe.snapshot()
        var attempts = 0
        while !state.started, attempts < 1_000 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(1))
            state = await probe.snapshot()
        }
        guard state.started else {
            work.cancel()
            await work.value
            Issue.record("Vorbereitungstask startete nicht innerhalb einer Sekunde")
            return
        }

        #expect(session.cancelPreparation())
        await work.value
        state = await probe.snapshot()
        #expect(state.observedCancellation)
        #expect(!session.cancelPreparation())
    }

    @Test("Ein neuer GUI-Drop cancelt den laufenden Import-Task")
    func replacementImportCancelsRunningTask() async throws {
        let session = ConversionSession(settings: AudioSettings())
        let probe = PreparationCancellationProbe()
        let staleToken = session.beginImport()
        let work = Task {
            await session.runImportTask(staleToken) {
                await probe.markStarted()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    // CancellationError ist beim ersetzenden Drop erwartet.
                }
                await probe.markFinished(cancelled: Task.isCancelled)
            }
        }

        var state = await probe.snapshot()
        var attempts = 0
        while !state.started, attempts < 1_000 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(1))
            state = await probe.snapshot()
        }
        guard state.started else {
            work.cancel()
            await work.value
            Issue.record("GUI-Import-Task startete nicht innerhalb einer Sekunde")
            return
        }

        _ = session.beginImport()
        await work.value
        state = await probe.snapshot()
        #expect(state.observedCancellation)
    }

    @Test("Abbruch räumt nur Ressourcen seines Laufs auf")
    func contextsAreIsolated() throws {
        let firstDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HB_Temp_\(UUID().uuidString)")
        let secondDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HB_Temp_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: firstDirectory) }
        defer { try? FileManager.default.removeItem(at: secondDirectory) }
        try FFmpegWrapper.createOwnedTempDirectory(firstDirectory)
        try FFmpegWrapper.createOwnedTempDirectory(secondDirectory)
        let first = ConversionContext()
        let second = ConversionContext()
        first.registerTempDirectory(firstDirectory)
        second.registerTempDirectory(secondDirectory)

        first.cancel()

        #expect(first.isCancelled)
        #expect(!second.isCancelled)
        #expect(!FileManager.default.fileExists(atPath: firstDirectory.path))
        #expect(FileManager.default.fileExists(atPath: secondDirectory.path))
    }

    @Test("Ein Neustart macht nur die alte Completion ungültig")
    func rapidRestartKeepsNewContext() {
        let session = ConversionSession()
        let first = session.beginConversionRun()
        let second = session.beginConversionRun()
        #expect(first.isCancelled)
        #expect(session.isCurrentConversion(second.id))
        session.endConversion(first.id)
        #expect(session.isCurrentConversion(second.id))
    }

    @Test("Ereignisse eines alten Laufs erreichen den neuen Lauf nicht")
    func staleWorkerEventsAreDiscardedAfterRestart() async {
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        let first = session.beginConversionRun()
        session.enqueueLog("Veralteter Lauf", runID: first.id)

        let second = session.beginConversionRun()
        session.enqueueLog("Aktueller Lauf", runID: second.id)
        await session.flushConversionEvents()

        #expect(session.eventLogs.map(\.message) == ["Aktueller Lauf"])
        #expect(first.isCancelled)
        #expect(session.isCurrentConversion(second.id))
    }

    @Test("Reset, Fortschritt, Log und Abschluss bleiben in Sendereihenfolge")
    func workerEventsRemainOrderedThroughCompletion() async {
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        let context = session.beginConversionRun()
        let output = URL(fileURLWithPath: "/tmp/Buch.m4b")

        session.enqueueSegmentReset(title: "Finaler Lauf", runID: context.id)
        session.enqueueSegmentInitialization(index: 1, filename: "Kapitel", runID: context.id)
        session.enqueueProgress(
            0.6,
            segmentIndex: 1,
            segmentProgress: 0.5,
            runID: context.id
        )
        session.enqueueLog("Vor dem Abschluss", runID: context.id)
        session.enqueueConversionFinished(
            success: false,
            cancelled: false,
            completedOutputs: [output],
            runID: context.id
        )
        await session.flushConversionEvents()

        #expect(session.segmentProgress[0]?.filename == "Finaler Lauf")
        #expect(session.segmentProgress[1] == SegmentStatus(filename: "Kapitel", progress: 0.5))
        #expect(session.progress == 0.6)
        #expect(session.eventLogs.map(\.message) == [
            "Vor dem Abschluss",
            "🏁 Vorgang mit Fehlern beendet."
        ])
        #expect(session.completedOutputURLs == [output])
        #expect(session.lastConversionSucceeded == false)
        #expect(!session.isCurrentConversion(context.id))
    }

    @Test("Abbruch entfernt auch die laufbezogene Partial-Datei")
    func cancellationRemovesStagedOutput() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = FFmpegWrapper.stagingOutputURL(
            for: directory.appendingPathComponent("Buch.m4b")
        )
        try FFmpegWrapper.createOwnedStagingOutput(staged)
        try Data("unvollständig".utf8).write(to: staged)
        let context = ConversionContext()
        context.registerStagedOutput(staged)

        #expect(context.cancel())
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test("Ein bereits abgebrochener Lauf startet keinen neuen Prozess")
    func cancelledContextRejectsProcessStart() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("unerwartet-gestartet")
        let context = ConversionContext()
        #expect(context.cancel())

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        process.arguments = [sentinel.path]

        #expect(try !context.run(process))
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test("SIGTERM-resistenter Prozess wird vor der Dateibereinigung beendet")
    func cancellationEscalatesAndThenCleansFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = FFmpegWrapper.stagingOutputURL(
            for: directory.appendingPathComponent("Buch.m4b")
        )
        try FFmpegWrapper.createOwnedStagingOutput(staged)
        let context = ConversionContext()
        context.registerStagedOutput(staged)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "trap 'printf late > \"$1\"' TERM; printf READY; while :; do :; done",
            "hoerbuchkloeppler-test",
            staged.path
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        defer {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }

        #expect(try context.run(process))
        let ready = output.fileHandleForReading.readData(ofLength: 5)
        #expect(String(data: ready, encoding: .utf8) == "READY")

        let workerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            workerFinished.signal()
        }
        #expect(context.cancel())
        let cleanupFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            context.finishAfterCancellationCleanup { _ in }
            cleanupFinished.signal()
        }

        // Der komplette Swift-Testing-Lauf startet mehrere echte Prozesse
        // parallel. Die Produktions-Schonfrist bleibt 0,5 Sekunden; nur der
        // Test-Join erhält genug Spielraum für belastete CI-/Entwicklungs-Macs.
        let cleanupResult = cleanupFinished.wait(timeout: .now() + 5)
        let workerResult = workerFinished.wait(timeout: .now() + 5)

        #expect(cleanupResult == .success)
        #expect(workerResult == .success)
        #expect(!process.isRunning)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test("Abbruchmeldung und Bereinigungswarnung gehen dem Abschluss voraus")
    func cancellationCleanupPrecedesTerminalEvent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stagedDirectory = directory.appendingPathComponent(".Buch.partial-race.m4b")
        try FileManager.default.createDirectory(
            at: stagedDirectory,
            withIntermediateDirectories: true
        )

        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        let context = session.beginConversionRun()
        context.registerStagedOutput(stagedDirectory)
        let cancellationGate = BlockingGate()

        let cancellation = Task.detached {
            context.cancel {
                session.enqueueCancellationStarted(runID: context.id)
                cancellationGate.blockUntilReleased()
            }
        }
        cancellationGate.waitUntilBlocked()

        let finish = Task.detached {
            context.finishAfterCancellationCleanup { cancelled in
                session.enqueueConversionFinished(
                    success: false,
                    cancelled: cancelled,
                    completedOutputs: [],
                    runID: context.id
                )
            }
        }
        cancellationGate.release()

        #expect(await cancellation.value)
        await finish.value
        await session.flushConversionEvents()

        let messages = session.eventLogs.map(\.message)
        #expect(messages.count == 2)
        #expect(messages.first == "🛑 Vorgang wird abgebrochen und bereinigt.")
        #expect(messages.last?.contains("keine gültige Besitzer-Markierung") == true)
        #expect(session.conversionStatus == "Abgebrochen")
        #expect(!session.isCurrentConversion(context.id))
    }

    @Test("Cancel und Commit haben eine eindeutige Reihenfolge")
    func commitAndCancellationAreSerialized() throws {
        let cancelledContext = ConversionContext()
        #expect(cancelledContext.cancel())
        var mutationRan = false
        let committedAfterCancel = try cancelledContext.performCommit(isLastOutput: true) {
            mutationRan = true
        }
        #expect(!committedAfterCancel)
        #expect(!mutationRan)

        let finishedContext = ConversionContext()
        let committedBeforeCancel = try finishedContext.performCommit(isLastOutput: true) {
            mutationRan = true
        }
        #expect(committedBeforeCancel)
        #expect(!finishedContext.cancel())
    }

    @Test("Der Abschluss übernimmt die erfolgreichen Ziel-URLs in einer Nachricht")
    func conversionFinishCarriesCompletedOutputs() async {
        let session = ConversionSession(settings: AudioSettings())
        let context = session.beginConversionRun()
        let url = URL(fileURLWithPath: "/tmp/Buch-01.m4b")

        session.enqueueConversionFinished(
            success: false,
            cancelled: false,
            completedOutputs: [url],
            runID: context.id
        )
        await session.flushConversionEvents()

        // Auch bei einem Teilerfolg (success == false) kennt die Session damit
        // die bereits atomar übernommenen Dateien — die CLI listet sie auf,
        // statt fälschlich "keine gültige Datei" zu melden.
        #expect(session.lastConversionSucceeded == false)
        #expect(session.completedOutputURLs == [url])
    }

    @Test("Temporäres Verzeichnis erkennt den lebenden Besitzer")
    func temporaryDirectoryRecognizesLiveOwner() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HB_Temp_Test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FFmpegWrapper.createOwnedTempDirectory(directory)

        #expect(FFmpegWrapper.temporaryDirectoryHasLiveOwner(directory))
    }
}

@Suite("Review-Fixes – Kapitelvalidierung")
struct ChapterValidationTests {
    @Test("Nur lückenlose Kapitel über die vollständige Dateidauer sind gültig")
    func validatesChapterRanges() {
        let valid = [
            AudioFile.FFChapter(start: 0, end: 10, title: "Eins"),
            AudioFile.FFChapter(start: 10, end: 20, title: "Zwei")
        ]
        #expect(AudioFile.chaptersAreValid(valid, totalDuration: 20))
        #expect(!AudioFile.chaptersAreValid([
            AudioFile.FFChapter(start: 0, end: 0, title: "Leer")
        ], totalDuration: 20))
        #expect(!AudioFile.chaptersAreValid([
            AudioFile.FFChapter(start: 0, end: 10, title: "Eins"),
            AudioFile.FFChapter(start: 9, end: 20, title: "Überlappt")
        ], totalDuration: 20))
        #expect(!AudioFile.chaptersAreValid([
            AudioFile.FFChapter(start: .nan, end: 10, title: "Ungültig")
        ], totalDuration: 20))
        #expect(!AudioFile.chaptersAreValid([
            AudioFile.FFChapter(start: 1, end: 10, title: "Vorlauf fehlt"),
            AudioFile.FFChapter(start: 10, end: 20, title: "Zwei")
        ], totalDuration: 20))
        #expect(!AudioFile.chaptersAreValid([
            AudioFile.FFChapter(start: 0, end: 9, title: "Eins"),
            AudioFile.FFChapter(start: 10, end: 20, title: "Lücke")
        ], totalDuration: 20))
        #expect(!AudioFile.chaptersAreValid(valid, totalDuration: 25))
        #expect(!AudioFile.chaptersAreValid(valid, totalDuration: 19))
        #expect(!AudioFile.chaptersAreValid([
            AudioFile.FFChapter(start: 0, end: 20.1, title: "Eins"),
            AudioFile.FFChapter(start: 20.1, end: 20.2, title: "Nach Dateiende")
        ], totalDuration: 20))
        #expect(!AudioFile.chaptersAreValid([
            AudioFile.FFChapter(start: 0, end: 20.1, title: "Eins"),
            AudioFile.FFChapter(start: 19.9, end: 20.2, title: "Würde beim Runden invertiert")
        ], totalDuration: 20))
    }
}

@Suite("Review-Fixes – Metadaten und CLI-Handoff")
@MainActor
struct MetadataAndCLITests {
    @Test("Ein veralteter Ordner-Scan darf einen neuen Import nicht überschreiben")
    func staleFolderScanIsIgnored() async {
        let session = ConversionSession()
        let staleToken = session.beginImport()
        _ = session.beginImport()
        let file = AudioFile(
            url: URL(fileURLWithPath: "/tmp/alt.mp3"),
            startTime: 0,
            duration: 1,
            chapterTitle: "Alt"
        )
        let scanned = ConversionSession.ScannedFolder(
            folderURL: URL(fileURLWithPath: "/tmp/alt"),
            audioFiles: [file],
            imageURLs: [],
            embeddedArtwork: nil
        )

        await session.applyScannedFolder(scanned, importToken: staleToken)
        #expect(session.audioFiles.isEmpty)
    }

    @Test("CLI-Handoff wird nach nicht darstellbarer Kapiteledition deaktiviert")
    func cliRepresentabilityTracksChapterEdits() async {
        let session = ConversionSession()
        session.title = "Buch"
        session.author = "Autor"
        let source = URL(fileURLWithPath: "/tmp/buch")
        let file = AudioFile(
            url: source.appendingPathComponent("01.mp3"),
            startTime: 0,
            duration: 1,
            chapterTitle: "Kapitel 1"
        )
        await session.applyScannedFolder(.init(
            folderURL: source,
            audioFiles: [file],
            imageURLs: [],
            embeddedArtwork: nil
        ))
        #expect(session.cliFolderIfRepresentable == source)

        session.audioFiles[0].chapterTitle = "Manuell geändert"
        #expect(session.cliFolderIfRepresentable == nil)
    }

    @Test("Mehrdeutige oder fehlende Tags öffnen die manuelle Auswahl")
    func metadataSelectionDecision() {
        let ambiguous = [
            TagCandidate(type: "Tag", key: "Album", value: "A"),
            TagCandidate(type: "Tag", key: "Title", value: "B")
        ]
        let resolution = ConversionSession.resolveMetadata(
            currentTitle: "",
            currentAuthor: "",
            titleCandidates: ambiguous,
            authorCandidates: []
        )
        #expect(resolution.title.isEmpty)
        #expect(resolution.author.isEmpty)
        #expect(resolution.shouldShowSelection)
    }

    @Test("Headless nimmt bei mehrdeutigen Tags den ersten Kandidaten statt leer zu bleiben")
    func headlessAmbiguityPrefersFirstCandidate() {
        // Kandidaten-Reihenfolge aus `metadataCandidates`: Album vor Title,
        // Performer vor Album_Performer. Die CLI hat keine Auswahl-UI und muss
        // deshalb selbst entscheiden.
        let resolution = ConversionSession.resolveMetadata(
            currentTitle: "",
            currentAuthor: "",
            titleCandidates: [
                TagCandidate(type: "MediaInfo", key: "Album", value: "Buchtitel"),
                TagCandidate(type: "MediaInfo", key: "Title", value: "Kapitel 1")
            ],
            authorCandidates: [
                TagCandidate(type: "MediaInfo", key: "Performer", value: "Autor"),
                TagCandidate(type: "MediaInfo", key: "Album_Performer", value: "Verlag")
            ],
            allowsSelectionUI: false
        )
        #expect(resolution.title == "Buchtitel")
        #expect(resolution.author == "Autor")
        #expect(!resolution.shouldShowSelection)
    }

    @Test("Headless ohne brauchbare Kandidaten bleibt leer und verlangt keine Auswahl")
    func headlessWithoutCandidatesStaysEmpty() {
        let resolution = ConversionSession.resolveMetadata(
            currentTitle: "",
            currentAuthor: "",
            titleCandidates: [],
            authorCandidates: [TagCandidate(type: "MediaInfo", key: "Performer", value: "   ")],
            allowsSelectionUI: false
        )
        #expect(resolution.title.isEmpty)
        #expect(resolution.author.isEmpty)
        #expect(!resolution.shouldShowSelection)
    }

    @Test("Metadatenwerte werden vor der Entscheidung bereinigt")
    func metadataValuesAreNormalized() {
        let resolution = ConversionSession.resolveMetadata(
            currentTitle: "",
            currentAuthor: "",
            titleCandidates: [
                TagCandidate(type: "Tag", key: "Album", value: " Buch "),
                TagCandidate(type: "Tag", key: "Title", value: "Buch")
            ],
            authorCandidates: [
                TagCandidate(type: "Tag", key: "Artist", value: "   ")
            ]
        )
        #expect(resolution.title == "Buch")
        #expect(resolution.author.isEmpty)
        #expect(resolution.shouldShowSelection)
    }

    @Test("Je ein eindeutiger Tag wird automatisch übernommen")
    func uniqueMetadataIsFilled() {
        let resolution = ConversionSession.resolveMetadata(
            currentTitle: "",
            currentAuthor: "",
            titleCandidates: [TagCandidate(type: "Tag", key: "Album", value: "Buch")],
            authorCandidates: [TagCandidate(type: "Tag", key: "Artist", value: "Autor")]
        )
        #expect(resolution.title == "Buch")
        #expect(resolution.author == "Autor")
        #expect(!resolution.shouldShowSelection)
    }

    @Test("CLI-Befehl enthält alle GUI-Optionen und quotet Shell-Metazeichen")
    func completeShellSafeCLICommand() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("kloeppler tool's")
        try makeExecutable(executable, contents: """
        #!/bin/sh
        for argument in "$@"; do
            printf '%s\\000' "$argument"
        done
        """)

        var settings = AudioSettings()
        settings.useParallelEncoding = false
        settings.bitrate = "64k"
        settings.sampleRate = 44_100
        settings.maxDurationHours = 9
        settings.isMono = false
        settings.isVerbose = true
        let invocation = CLIInvocation(
            executable: executable.path,
            folderURL: URL(fileURLWithPath: "/tmp/Buch $HOME's"),
            settings: settings,
            title: "Titel `printf nicht-ausführen`",
            author: "O'Brien",
            genre: "Roman & Lesung",
            coverPath: "/tmp/Cover Bild.jpg"
        )

        #expect(invocation.arguments.contains("--max-duration"))
        #expect(invocation.arguments.contains("--title"))
        #expect(invocation.arguments.contains("--author"))
        #expect(invocation.arguments.contains("--genre"))
        #expect(invocation.arguments.contains("--cover"))
        #expect(invocation.arguments.contains("--stereo"))
        #expect(invocation.arguments.contains("--verbose"))

        // Der echte Shell-Durchlauf prüft das beobachtbare Verhalten: Weder
        // Dollarzeichen noch Backticks, Apostrophe oder Leerzeichen dürfen die
        // Argumentgrenzen oder Inhalte verändern.
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", invocation.shellCommand]
        process.standardOutput = outputPipe
        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let receivedArguments = output.split(separator: 0).map {
            String(decoding: $0, as: UTF8.self)
        }

        #expect(process.terminationStatus == 0)
        #expect(receivedArguments == invocation.arguments)
    }

    @Test("CLI-Handoff kann ein automatisch gefundenes Cover bewusst unterdrücken")
    func cliInvocationCanSuppressCover() {
        let invocation = CLIInvocation(
            executable: "kloeppler",
            folderURL: URL(fileURLWithPath: "/tmp/Buch"),
            settings: AudioSettings(),
            title: "Buch",
            author: "Autor",
            suppressCover: true
        )

        #expect(invocation.arguments.contains("--no-cover"))
        #expect(!invocation.arguments.contains("--cover"))
        // Default-Settings haben isVerbose == false — dann auch kein --verbose.
        #expect(!invocation.arguments.contains("--verbose"))
    }

    @Test("UTF-16-MediaInfo-JSON wird erst nach erfolgreichem JSON-Parse akzeptiert")
    func utf16MediaInfoJSONIsDecoded() throws {
        let json = """
        {"media":{"track":[{"@type":"General","Album":"Buch","Performer":"Autor"}]}}
        """
        let data = try #require(json.data(using: .utf16))
        let general = try #require(ConversionSession.decodeMediaInfoGeneralTrack(from: data))

        #expect(general["Album"] as? String == "Buch")
        #expect(general["Performer"] as? String == "Autor")
    }

    @Test("Rohe UTF-16-MediaInfo-Ausgabe wird nicht als MacRoman-Zeichensalat akzeptiert")
    func utf16MediaInfoTextIsDecoded() throws {
        let text = "Titel: Hörbuch"
        let data = try #require(text.data(using: .utf16))

        #expect(ConversionSession.decodeMediaInfoText(from: data) == text)
    }
}

@Suite("Review-Fixes – Import-Lebenszyklus")
@MainActor
struct ImportLifecycleTests {
    @Test("Kopierbares Log wächst zeilenweise und wird vollständig zurückgesetzt")
    func copyableLogPreservesOrderAndReset() {
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }

        session.addLog("Erste Zeile")
        session.addLog("Zweite Zeile", type: .highlight)
        session.addLog("Dritte Zeile", type: .dim)

        #expect(session.logString == "Erste Zeile\nZweite Zeile\nDritte Zeile")
        #expect(session.eventLogs.map(\.message) == ["Erste Zeile", "Zweite Zeile", "Dritte Zeile"])

        session.resetSession()
        #expect(session.logString.isEmpty)
        #expect(session.eventLogs.isEmpty)
    }

    @Test("Getrennte Provider behalten beim gleichen Ziel nur die Symlink-Kapitelgruppe")
    func providerResultsAreDeduplicatedByReadURL() async {
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        let token = session.beginImport(expectedItemCount: 2)
        let target = URL(fileURLWithPath: "/tmp/Original.m4b")
        let link = URL(fileURLWithPath: "/tmp/Bewusst benannt.m4b")
        let directFile = FoundFile(source: target, resolved: target)
        let linkedFile = FoundFile(source: link, resolved: target)
        let directChapters = [
            AudioFile(foundFile: directFile, startTime: 0, duration: 1, chapterTitle: "Direkt 1"),
            AudioFile(foundFile: directFile, startTime: 1, duration: 1, chapterTitle: "Direkt 2")
        ]
        let linkedChapters = [
            AudioFile(foundFile: linkedFile, startTime: 0, duration: 1, chapterTitle: "Link 1"),
            AudioFile(foundFile: linkedFile, startTime: 1, duration: 1, chapterTitle: "Link 2")
        ]

        await session.processIncomingFiles(
            directChapters,
            skipCoverExtraction: true,
            importToken: token
        )
        await session.finishImport(token)
        await session.processIncomingFiles(
            linkedChapters,
            skipCoverExtraction: true,
            importToken: token
        )
        await session.finishImport(token)

        #expect(session.audioFiles.map(\.chapterTitle) == ["Link 1", "Link 2"])
        #expect(session.audioFiles.allSatisfy { $0.sourceURL == link })
        #expect(session.eventLogs.contains { $0.message.contains("1 Audiodatei mit 2 Kapiteln") })
        #expect(session.eventLogs.contains { $0.message.contains("lesen dieselbe Audiodatei") })
    }

    @Test("Doppelte Provider-Ergebnisse behalten jedes Containerkapitel genau einmal")
    func identicalProviderResultsAreDeduplicatedBySegment() {
        let container = URL(fileURLWithPath: "/tmp/Buch.m4b")
        let chapters = [
            AudioFile(url: container, startTime: 0, duration: 1, chapterTitle: "Eins"),
            AudioFile(url: container, startTime: 1, duration: 2, chapterTitle: "Zwei")
        ]

        let result = ConversionSession.deduplicateAudioFiles(chapters + chapters)

        #expect(result.files.count == 2)
        #expect(result.files.map(\.chapterTitle) == ["Eins", "Zwei"])
        #expect(result.discardedSources.count == 2)
    }

    @Test("Ein Analysefehler verwirft den gesamten Mehrfach-Drop")
    func failedProviderRejectsWholeBatch() async {
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        let existing = AudioFile(
            url: URL(fileURLWithPath: "/tmp/vorher.mp3"),
            startTime: 0,
            duration: 1,
            chapterTitle: "Vorher"
        )
        await session.processIncomingFiles([existing], skipCoverExtraction: true)

        let token = session.beginImport(expectedItemCount: 2)
        let staged = AudioFile(
            url: URL(fileURLWithPath: "/tmp/neu.mp3"),
            startTime: 0,
            duration: 1,
            chapterTitle: "Neu"
        )
        session.stageAudioLoadResult(
            .success(files: [staged], warnings: []),
            importToken: token
        )
        await session.finishImport(token)
        #expect(session.audioFiles.map(\.id) == [existing.id])

        let brokenURL = URL(fileURLWithPath: "/tmp/kaputt.mp3")
        session.stageAudioLoadResult(
            .failure(AudioImportFailure(sourceURL: brokenURL, reason: .analysisFailed)),
            importToken: token
        )
        await session.finishImport(token)

        #expect(session.audioFiles.map(\.id) == [existing.id])
        #expect(session.lastImportFailures == [
            AudioImportFailure(sourceURL: brokenURL, reason: .analysisFailed)
        ])
        #expect(session.importErrorMessage?.contains("vollständig verworfen") == true)
        #expect(!session.isImporting)
    }

    @Test("Skip und Abbruch bleiben vom Analysefehler getrennt")
    func skippedAndCancelledProvidersUseDistinctPolicies() async {
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        let accepted = AudioFile(
            url: URL(fileURLWithPath: "/tmp/akzeptiert.mp3"),
            startTime: 0,
            duration: 1,
            chapterTitle: "Akzeptiert"
        )
        let skippedToken = session.beginImport(expectedItemCount: 2)
        session.stageAudioLoadResult(
            .success(files: [accepted], warnings: []),
            importToken: skippedToken
        )
        await session.finishImport(skippedToken)
        session.stageAudioLoadResult(.skipped, importToken: skippedToken)
        await session.finishImport(skippedToken)

        #expect(session.audioFiles.map(\.id) == [accepted.id])
        #expect(session.lastImportFailures.isEmpty)
        #expect(session.importErrorMessage == nil)

        let discarded = AudioFile(
            url: URL(fileURLWithPath: "/tmp/verworfen.mp3"),
            startTime: 0,
            duration: 1,
            chapterTitle: "Verworfen"
        )
        let cancelledToken = session.beginImport(expectedItemCount: 2)
        session.stageAudioLoadResult(
            .success(files: [discarded], warnings: []),
            importToken: cancelledToken
        )
        await session.finishImport(cancelledToken)
        session.stageAudioLoadResult(.cancelled, importToken: cancelledToken)
        await session.finishImport(cancelledToken)

        #expect(session.audioFiles.map(\.id) == [accepted.id])
        #expect(session.lastImportFailures.isEmpty)
        #expect(session.importErrorMessage == nil)
        #expect(!session.isImporting)
    }

    @Test("Artwork-Kandidaten enthalten jede physische Datei nur einmal")
    func artworkCandidatesDeduplicateContainerChapters() {
        let source = URL(fileURLWithPath: "/tmp/Buch.m4b")
        let files = [
            AudioFile(url: source, startTime: 0, duration: 1, chapterTitle: "1"),
            AudioFile(url: source, startTime: 1, duration: 1, chapterTitle: "2"),
            AudioFile(
                url: URL(fileURLWithPath: "/tmp/Zweites.m4a"),
                startTime: 0,
                duration: 1,
                chapterTitle: "3"
            )
        ]

        let candidates = ConversionSession.uniqueArtworkCandidates(files)

        #expect(candidates.map { $0.url.lastPathComponent } == ["Buch.m4b", "Zweites.m4a"])
    }

    @Test("Ungültige eingebettete Bilddaten werden nicht als Cover gespeichert")
    func invalidEmbeddedArtworkIsRejected() async {
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }

        await session.applyScannedFolder(.init(
            folderURL: URL(fileURLWithPath: "/tmp/Buch"),
            audioFiles: [],
            imageURLs: [],
            embeddedArtwork: Data("kein Bild".utf8)
        ))

        #expect(session.coverImage == nil)
        #expect(session.coverPath == nil)
        #expect(session.embeddedCoverData == nil)
    }

    @Test("MediaInfo-Fehler entfernt Kandidaten des vorherigen Imports")
    func metadataFailureClearsStaleCandidates() async {
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        session.titleCandidates = [TagCandidate(type: "Alt", key: "Title", value: "Falscher Titel")]
        session.authorCandidates = [TagCandidate(type: "Alt", key: "Artist", value: "Falscher Autor")]
        let token = session.beginImport()
        let missing = AudioFile(
            url: URL(fileURLWithPath: "/tmp/fehlt-\(UUID().uuidString).mp3"),
            startTime: 0,
            duration: 1,
            chapterTitle: "Fehlt"
        )

        await session.processIncomingFiles(
            [missing],
            skipCoverExtraction: true,
            importToken: token
        )
        await session.finishImport(token)

        #expect(session.titleCandidates.isEmpty)
        #expect(session.authorCandidates.isEmpty)
        #expect(session.showSelectionUI)
    }

    @Test("Alle löschen entwertet noch laufende Drop-Ergebnisse")
    func clearingFilesInvalidatesPendingImport() async {
        let session = ConversionSession(settings: AudioSettings())
        let token = session.beginImport(expectedItemCount: 1)
        let source = URL(fileURLWithPath: "/tmp/aktuell")
        let file = AudioFile(
            url: source.appendingPathComponent("01.mp3"),
            startTime: 0,
            duration: 1,
            chapterTitle: "Kapitel"
        )
        await session.processIncomingFiles([file], skipCoverExtraction: true, importToken: token)
        #expect(session.isImporting)

        session.audioFiles.removeAll()
        await session.applyScannedFolder(.init(
            folderURL: URL(fileURLWithPath: "/tmp/veraltet"),
            audioFiles: [file],
            imageURLs: [],
            embeddedArtwork: nil
        ), importToken: token)
        await session.finishImport(token)

        #expect(session.audioFiles.isEmpty)
        #expect(!session.isImporting)
    }

    @Test("Mehrteiliger Drop bleibt bis zum letzten Provider im Importzustand")
    func pendingImportCountsAllProviders() async {
        let session = ConversionSession(settings: AudioSettings())
        let token = session.beginImport(expectedItemCount: 2)

        await session.finishImport(token)
        #expect(session.isImporting)
        await session.finishImport(token)
        #expect(!session.isImporting)
    }

    @Test("Verspäteter Provider startet keine Analyse im neuen Importlauf")
    func staleProviderDoesNotEnterReplacementContext() async {
        let session = ConversionSession(settings: AudioSettings())
        let staleToken = session.beginImport()
        _ = session.beginImport()
        var executed = false

        await session.runImportTask(staleToken) {
            executed = true
        }

        #expect(!executed)
    }

    @Test("Leerer Provider entwertet gültigen Teil eines Mehrfach-Drops nicht")
    func emptyProviderDoesNotInvalidateDrop() async {
        let session = ConversionSession(settings: AudioSettings())
        let token = session.beginImport(expectedItemCount: 2)
        await session.processIncomingFiles([], skipCoverExtraction: true, importToken: token)
        await session.finishImport(token)

        let file = AudioFile(
            url: URL(fileURLWithPath: "/tmp/gueltig.mp3"),
            startTime: 0,
            duration: 1,
            chapterTitle: "Gültig"
        )
        await session.processIncomingFiles([file], skipCoverExtraction: true, importToken: token)
        await session.finishImport(token)

        #expect(session.audioFiles.map(\.id) == [file.id])
    }

    @Test("Bewusst entferntes Cover wird nicht automatisch wieder eingesetzt")
    func suppressedCoverStaysRemoved() async {
        let session = ConversionSession(settings: AudioSettings())
        session.removeCover()
        await session.applyScannedFolder(.init(
            folderURL: URL(fileURLWithPath: "/tmp/Buch"),
            audioFiles: [],
            imageURLs: [URL(fileURLWithPath: "/tmp/folder.jpg")],
            embeddedArtwork: Data("kein echtes Bild".utf8)
        ))

        #expect(session.coverImage == nil)
        #expect(session.coverPath == nil)
        #expect(session.embeddedCoverData == nil)
        #expect(session.isCoverSuppressed)
    }
}

@Suite("Review-Fixes – Einstellungen")
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
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SettingsManager(settingsURL: directory.appendingPathComponent("settings.json"))

        #expect(manager.loadSettings() == AudioSettings())
    }

    @Test("Ein fehlendes oder falsch typisiertes JSON-Feld verwirft keine gültigen Nachbarn")
    func malformedJSONFieldFallsBackIndividually() throws {
        let directory = try temporaryDirectory()
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
        let directory = try temporaryDirectory()
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
}

@Suite("Review-Fixes 2026-08-17 – Symlinks und Staging-Bereinigung")
@MainActor
struct ReviewFixes20260817Tests {
    @Test("Links gewinnen gegen danebenliegende Ziele und bestimmen die Reihenfolge")
    func symlinksReplaceAdjacentTargetsWithoutDuplicateImport() async throws {
        // Zwei gegenläufig benannte Link-/Ziel-Paare: die vom Nutzer gewollte
        // Reihenfolge (01, 02) ist genau die umgekehrte der Zielnamen (A, B).
        // Wird nur das aufgelöste Ziel weitergereicht, kippt die Reihenfolge
        // (Review-Fund 2026-08-17).
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let zielB = directory.appendingPathComponent("Original-B.wav")
        let zielA = directory.appendingPathComponent("Original-A.wav")
        try writeSilentWAV(to: zielB)
        try writeSilentWAV(to: zielA)
        let linkEins = directory.appendingPathComponent("01.wav")
        let linkZwei = directory.appendingPathComponent("02.wav")
        try FileManager.default.createSymbolicLink(at: linkEins, withDestinationURL: zielB)
        try FileManager.default.createSymbolicLink(at: linkZwei, withDestinationURL: zielA)

        let session = ConversionSession(settings: AudioSettings())
        let scanned = await session.scanFolder(directory)
        await session.applyScannedFolder(scanned)

        #expect(session.audioFiles.map(\.name) == ["01.wav", "02.wav"])
        #expect(session.audioFiles.map { $0.url.lastPathComponent } == [
            "Original-B.wav", "Original-A.wav"
        ])
        #expect(session.eventLogs.contains { $0.message.contains("Mehrere Ordner-Einträge") })
    }

    @Test("Name und Fallback-Kapiteltitel folgen dem Linknamen, gelesen wird das Ziel")
    func audioFileNameFollowsSourcePath() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ziel = directory.appendingPathComponent("Original-B.wav")
        try Data("B".utf8).write(to: ziel)
        let link = directory.appendingPathComponent("01.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ziel)

        // Ohne Titel-Tag (die Datei ist kein echtes Audio) greift der Fallback.
        let datei = await AudioFile(foundFile: FoundFile(source: link, resolved: ziel))

        #expect(datei.name == "01.wav")
        #expect(datei.chapterTitle == "01")
        #expect(datei.url.lastPathComponent == "Original-B.wav")
    }

    @Test("Ein Link ohne Endung wird über die Zielendung als Audio erkannt")
    func extensionlessSymlinkUsesResolvedAudioType() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("Original.wav")
        try writeSilentWAV(to: target)
        let link = directory.appendingPathComponent("01")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let session = ConversionSession(settings: AudioSettings())
        let found = try #require(ConversionSession.foundFile(at: link))
        let loaded = await session.loadAudioFiles(from: found)

        #expect(loaded.files.count == 1)
        #expect(loaded.files.first?.name == "01")
        #expect(loaded.files.first?.url == target.resolvingSymlinksInPath())
    }

    @Test("Falsche sichtbare Audio-Endung importiert keine Null-Dauer-Datei")
    func misleadingAudioExtensionIsLoggedAndSkipped() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("Notiz.txt")
        try Data("kein Audio".utf8).write(to: target)
        let link = directory.appendingPathComponent("01.mp3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let session = ConversionSession(settings: AudioSettings())
        let found = try #require(ConversionSession.foundFile(at: link))
        let loaded = await session.loadAudioFiles(from: found)

        #expect(loaded.files.isEmpty)
        #expect(loaded.failures.count == 1)
        #expect(loaded.failures.first?.sourceURL == link)
        #expect(loaded.failures.first?.reason == .analysisFailed)
    }

    @Test("Video-only-MP4 wird bereits bei der Audioanalyse abgewiesen")
    func videoOnlyMP4IsRejectedBeforeConversion() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("nur-video.mp4")
        let ffmpeg = try #require(FFmpegWrapper.getBinaryURL(name: "ffmpeg"))
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-nostdin", "-v", "error", "-f", "lavfi", "-i",
            "color=c=black:s=16x16:d=0.2", "-an", "-c:v", "mpeg4", video.path
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        let found = try #require(ConversionSession.foundFile(at: video))
        let loaded = await session.loadAudioFiles(from: found)
        await Task.yield()

        #expect(loaded.files.isEmpty)
        #expect(loaded.failures.first?.reason == .noAudioTrack)
        #expect(!session.eventLogs.contains { $0.message.contains("Keine Kapitel") })

        let folderSession = ConversionSession(settings: AudioSettings())
        folderSession.logSink = { _ in }
        folderSession.beginPreparation()
        await folderSession.prepareFolder(directory, analyzeArtwork: false)
        #expect(folderSession.audioFiles.isEmpty)
        #expect(folderSession.lastImportFailures.first?.reason == .noAudioTrack)
        #expect(folderSession.importErrorMessage?.contains("vollständig verworfen") == true)
    }

    @Test("Kapitelcontainer und Bilder dürfen nur am Ziel eine Endung tragen")
    func resolvedExtensionsDetermineContainersAndImages() {
        let chapter = FoundFile(
            source: URL(fileURLWithPath: "/tmp/Teil 1"),
            resolved: URL(fileURLWithPath: "/tmp/Buch.m4b")
        )
        let image = FoundFile(
            source: URL(fileURLWithPath: "/tmp/cover"),
            resolved: URL(fileURLWithPath: "/tmp/Cover.jpg")
        )
        let misleading = FoundFile(
            source: URL(fileURLWithPath: "/tmp/Teil.m4b"),
            resolved: URL(fileURLWithPath: "/tmp/Notiz.txt")
        )

        #expect(chapter.kind == .audio)
        #expect(chapter.isChapterContainer)
        #expect(image.kind == .image)
        #expect(!misleading.isChapterContainer)
    }

    @Test("Kapitelextraktion prüft die Lese-URL statt des sichtbaren Namens")
    func chapterExtractionUsesResolvedExtension() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = directory.appendingPathComponent("Buch.m4b")
        try Data("kein echter Container".utf8).write(to: container)
        let extensionless = FoundFile(
            source: directory.appendingPathComponent("Teil 1"),
            resolved: container
        )
        let misleading = FoundFile(
            source: directory.appendingPathComponent("Teil 2.m4b"),
            resolved: directory.appendingPathComponent("Notiz.txt")
        )

        let fallback = await AudioFile.extractChapters(from: extensionless)
        let ignored = await AudioFile.extractChapters(from: misleading)
        #expect(fallback?.first?.name == "Teil 1")
        #expect(ignored == nil)
    }

    @Test("Unterordner werden vor Dateinamen sortiert")
    func nestedFoldersKeepDiscOrder() async {
        let root = URL(fileURLWithPath: "/tmp/Buch")
        let paths = ["CD2/02.mp3", "CD1/02.mp3", "CD2/01.mp3", "CD1/01.mp3"]
        let files = paths.map { path in
            let url = root.appendingPathComponent(path)
            return AudioFile(
                foundFile: FoundFile(source: url, resolved: url),
                startTime: 0,
                duration: 1,
                chapterTitle: path
            )
        }
        let session = ConversionSession(settings: AudioSettings())

        await session.processIncomingFiles(files, skipCoverExtraction: true)

        #expect(session.audioFiles.map(\.chapterTitle) == [
            "CD1/01.mp3", "CD1/02.mp3", "CD2/01.mp3", "CD2/02.mp3"
        ])
    }

    @Test("Eine gewöhnliche Datei führt beide Pfade identisch")
    func plainFileHasIdenticalPaths() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let datei = directory.appendingPathComponent("Kapitel.wav")
        try Data("x".utf8).write(to: datei)

        let audio = await AudioFile(url: datei)

        #expect(audio.name == "Kapitel.wav")
        #expect(audio.sourceURL == audio.url)
    }

    @Test("discardStagedOutput löscht einen untergeschobenen Ordner nicht rekursiv")
    func discardStagedOutputDoesNotDeleteDirectories() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = directory.appendingPathComponent(".Buch.partial-1234.m4b")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let inhalt = staging.appendingPathComponent("wichtig.txt")
        try Data("nicht löschen".utf8).write(to: inhalt)

        let logs = ThreadSafeLogProbe()
        let context = ConversionContext { _, message in logs.append(message) }
        context.registerStagedOutput(staging)
        context.discardStagedOutput(staging)

        #expect(FileManager.default.fileExists(atPath: inhalt.path))
        #expect(logs.snapshot().contains { $0.contains("Besitzer-Markierung") })
    }

    @Test("cancel löscht einen untergeschobenen Ordner nicht rekursiv")
    func cancelDoesNotDeleteDirectories() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = directory.appendingPathComponent(".Buch.partial-5678.m4b")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let inhalt = staging.appendingPathComponent("wichtig.txt")
        try Data("nicht löschen".utf8).write(to: inhalt)

        let context = ConversionContext()
        context.registerStagedOutput(staging)
        context.cancel()

        #expect(FileManager.default.fileExists(atPath: inhalt.path))
    }

}
