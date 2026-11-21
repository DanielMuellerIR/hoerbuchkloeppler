import Foundation
import Testing
@testable import HoerbuchkloepplerCore

@Suite("Quellpfade, Dateitypen und Reihenfolge")
@MainActor
struct SourceDiscoveryTests {
    @Test("Links gewinnen gegen danebenliegende Ziele und bestimmen die Reihenfolge")
    func symlinksReplaceAdjacentTargetsWithoutDuplicateImport() async throws {
        // Zwei gegenläufig benannte Link-/Ziel-Paare: die vom Nutzer gewollte
        // Reihenfolge (01, 02) ist genau die umgekehrte der Zielnamen (A, B).
        // Das aufgelöste Ziel allein würde die Reihenfolge umkehren.
        let directory = try makeTestDirectory()
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
        await session.importURLs([directory])

        #expect(session.cliFolderIfRepresentable == directory)
        #expect(session.importCompletedItems == session.importTotalItems)

        #expect(session.audioFiles.map(\.name) == ["01.wav", "02.wav"])
        #expect(session.audioFiles.map { $0.url.lastPathComponent } == [
            "Original-B.wav", "Original-A.wav"
        ])
        #expect(session.eventLogs.contains { $0.message.contains("Mehrere Ordner-Einträge") })
    }

    @Test("Name und Fallback-Kapiteltitel folgen dem Linknamen, gelesen wird das Ziel")
    func audioFileNameFollowsSourcePath() async throws {
        let directory = try makeTestDirectory()
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
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("Original.wav")
        try writeSilentWAV(to: target)
        let link = directory.appendingPathComponent("01")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let session = ConversionSession(settings: AudioSettings())
        let found = try #require(SourceDiscovery.foundFile(at: link))
        let loaded = await session.loadAudioFiles(from: found)

        #expect(loaded.files.count == 1)
        #expect(loaded.files.first?.name == "01")
        #expect(loaded.files.first?.url == target.resolvingSymlinksInPath())
    }

    @Test("Falsche sichtbare Audio-Endung importiert keine Null-Dauer-Datei")
    func misleadingAudioExtensionIsLoggedAndSkipped() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("Notiz.txt")
        try Data("kein Audio".utf8).write(to: target)
        let link = directory.appendingPathComponent("01.mp3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let session = ConversionSession(settings: AudioSettings())
        let found = try #require(SourceDiscovery.foundFile(at: link))
        let loaded = await session.loadAudioFiles(from: found)

        #expect(loaded.files.isEmpty)
        #expect(loaded.failures.count == 1)
        #expect(loaded.failures.first?.source == .file(link))
        #expect(loaded.failures.first?.reason == .analysisFailed)
    }

    @Test("Video-only-MP4 wird bereits bei der Audioanalyse abgewiesen")
    func videoOnlyMP4IsRejectedBeforeConversion() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("nur-video.mp4")
        let ffmpeg = try #require(ToolLocator.binaryURL(name: "ffmpeg"))
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
        let found = try #require(SourceDiscovery.foundFile(at: video))
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

        let valid = directory.appendingPathComponent("Gueltig", isDirectory: true)
        try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: false)
        try writeSilentWAV(to: valid.appendingPathComponent("Kapitel.wav"))
        await folderSession.prepareFolder(valid, analyzeArtwork: false)
        #expect(folderSession.audioFiles.count == 1)
        #expect(folderSession.lastImportFailures.isEmpty)
        #expect(folderSession.importErrorMessage == nil)
        #expect(!folderSession.showSelectionUI)
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
        let directory = try makeTestDirectory()
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

        await session.importAnalyzedFiles(files, analyzeArtwork: false)

        #expect(session.audioFiles.map(\.chapterTitle) == [
            "CD1/01.mp3", "CD1/02.mp3", "CD2/01.mp3", "CD2/02.mp3"
        ])
    }

    @Test("Eine gewöhnliche Datei führt beide Pfade identisch")
    func plainFileHasIdenticalPaths() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let datei = directory.appendingPathComponent("Kapitel.wav")
        try Data("x".utf8).write(to: datei)

        let audio = await AudioFile(url: datei)

        #expect(audio.name == "Kapitel.wav")
        #expect(audio.sourceURL == audio.url)
    }
}
