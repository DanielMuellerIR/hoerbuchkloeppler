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
        try Data("neu".utf8).write(to: staged)

        #expect(try String(contentsOf: final, encoding: .utf8) == "alt")
        try FFmpegWrapper.commitStagedOutput(staged, to: final)
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
        try Data().write(to: staged)

        #expect(throws: (any Error).self) { try FFmpegWrapper.commitStagedOutput(staged, to: final) }
        #expect(try String(contentsOf: final, encoding: .utf8) == "behalten")
    }

    @Test("Staging-Dateien tragen die Besitzer-PID als Laufmarke im Namen")
    func stagingURLCarriesOwnerPID() {
        let final = URL(fileURLWithPath: "/tmp/Buch.m4b")
        let staged = FFmpegWrapper.stagingOutputURL(for: final)
        #expect(FFmpegWrapper.stagedOutputOwnerPID(staged) == ProcessInfo.processInfo.processIdentifier)
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
        for url in [orphan, alive, legacy, otherTarget] {
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

        FFmpegWrapper.removeOrphanedStagedOutputs(for: final)

        #expect(FileManager.default.fileExists(atPath: decoyDirectory.path))
        #expect(FileManager.default.fileExists(atPath: payload.path))
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
        // Auch die PATH-Auflösung muss den Symlink-Kandidaten akzeptieren.
        let resolved = FFmpegWrapper.resolveBinaryURL(
            name: "ffmpeg",
            bundledURL: nil,
            pathEnvironment: binDirectory.path,
            fallbackPaths: []
        )
        #expect(resolved == link)
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
}

@Suite("Review-Fixes – laufbezogener Abbruch")
@MainActor
struct CancellationIsolationTests {
    @Test("Abbruch räumt nur Ressourcen seines Laufs auf")
    func contextsAreIsolated() throws {
        let firstDirectory = try temporaryDirectory()
        let secondDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: secondDirectory) }
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

    @Test("Abbruch entfernt auch die laufbezogene Partial-Datei")
    func cancellationRemovesStagedOutput() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent(".Buch.partial-test.m4b")
        try Data("unvollständig".utf8).write(to: staged)
        let context = ConversionContext()
        context.registerStagedOutput(staged)

        #expect(context.cancel())
        #expect(!FileManager.default.fileExists(atPath: staged.path))
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
    func conversionFinishCarriesCompletedOutputs() async throws {
        let session = ConversionSession(settings: AudioSettings())
        let context = session.beginConversionRun()
        let url = URL(fileURLWithPath: "/tmp/Buch-01.m4b")

        session.enqueueConversionFinished(
            success: false,
            cancelled: false,
            completedOutputs: [url],
            runID: context.id
        )
        // Die Nachricht läuft als Main-Actor-Task; bis zu 1 s darauf warten.
        var attempts = 0
        while session.lastConversionSucceeded == nil, attempts < 1_000 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(1))
        }

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
            sourceURL: URL(fileURLWithPath: "/tmp/alt"),
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
            sourceURL: source,
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
    func completeShellSafeCLICommand() {
        var settings = AudioSettings()
        settings.useParallelEncoding = false
        settings.bitrate = "64k"
        settings.sampleRate = 44_100
        settings.maxDurationHours = 9
        settings.isMono = false
        settings.isVerbose = true
        let invocation = CLIInvocation(
            executable: "/tmp/kloeppler tool",
            folderURL: URL(fileURLWithPath: "/tmp/Buch $HOME's"),
            settings: settings,
            title: "Titel `touch /tmp/nope`",
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
        #expect(invocation.shellCommand.contains("'$HOME'" ) == false)
        #expect(invocation.shellCommand.contains("'\\''"))
        #expect(invocation.shellCommand.contains("'Titel `touch /tmp/nope`'"))
        #expect(invocation.shellCommand.contains("'/tmp/Cover Bild.jpg'"))
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
            sourceURL: URL(fileURLWithPath: "/tmp/veraltet"),
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
            sourceURL: URL(fileURLWithPath: "/tmp/Buch"),
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
