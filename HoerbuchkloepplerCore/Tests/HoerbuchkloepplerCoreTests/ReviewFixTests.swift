import Foundation
import Testing
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
}

@Suite("Review-Fixes – Metadaten und CLI-Handoff")
struct MetadataAndCLITests {
    @Test("Ein veralteter Ordner-Scan darf einen neuen Import nicht überschreiben")
    func staleFolderScanIsIgnored() {
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

        session.applyScannedFolder(scanned, importToken: staleToken)
        #expect(session.audioFiles.isEmpty)
    }

    @Test("CLI-Handoff wird nach nicht darstellbarer Kapiteledition deaktiviert")
    func cliRepresentabilityTracksChapterEdits() {
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
        session.applyScannedFolder(.init(
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
        let invocation = CLIInvocation(
            executable: "/tmp/kloeppler tool",
            folderURL: URL(fileURLWithPath: "/tmp/Buch $HOME's"),
            settings: settings,
            title: "Titel `touch /tmp/nope`",
            author: "O'Brien"
        )

        #expect(invocation.arguments.contains("--max-duration"))
        #expect(invocation.arguments.contains("--title"))
        #expect(invocation.arguments.contains("--author"))
        #expect(invocation.arguments.contains("--stereo"))
        #expect(invocation.shellCommand.contains("'$HOME'" ) == false)
        #expect(invocation.shellCommand.contains("'\\''"))
        #expect(invocation.shellCommand.contains("'Titel `touch /tmp/nope`'"))
    }
}
