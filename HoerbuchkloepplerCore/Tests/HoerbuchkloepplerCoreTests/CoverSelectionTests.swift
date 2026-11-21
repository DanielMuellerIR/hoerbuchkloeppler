import Foundation
import Testing
@testable import HoerbuchkloepplerCore

private func writeAudioWithEmbeddedCover(
    to audio: URL,
    coverData: Data,
    in directory: URL
) throws {
    let cover = directory.appendingPathComponent("cover-\(UUID().uuidString).png")
    try coverData.write(to: cover)
    let ffmpeg = try #require(ToolLocator.binaryURL(name: "ffmpeg"))
    let generated = ProcessRunner.capture(
        executableURL: ffmpeg,
        arguments: [
            "-nostdin", "-v", "error",
            "-f", "lavfi", "-i", "anullsrc=r=8000:cl=mono",
            "-i", cover.path,
            "-map", "0:a", "-map", "1:v",
            "-c:a", "aac", "-b:a", "8k", "-t", "0.25",
            "-c:v", "png", "-disposition:v", "attached_pic",
            audio.path
        ],
        timeout: 5
    )
    guard case .completed(let status, _) = generated, status == 0 else {
        Issue.record("ffmpeg konnte die Cover-Testdatei nicht erzeugen")
        return
    }
}

private actor ArtworkLoaderProbe {
    private let dataByURL: [URL: Data]
    private var calls: [URL] = []
    private var firstCallContinuation: CheckedContinuation<Void, Never>?
    private var firstCallStarted = false
    private var firstCallReleased = false

    init(dataByURL: [URL: Data]) {
        self.dataByURL = dataByURL
    }

    func load(_ url: URL) async -> Data? {
        calls.append(url)
        if calls.count == 1 {
            firstCallStarted = true
            if !firstCallReleased {
                await withCheckedContinuation { continuation in
                    firstCallContinuation = continuation
                }
            }
        }
        return dataByURL[url]
    }

    func snapshot() -> (started: Bool, calls: [URL]) {
        (firstCallStarted, calls)
    }

    func releaseFirstCall() {
        firstCallReleased = true
        firstCallContinuation?.resume()
        firstCallContinuation = nil
    }
}

@Suite("ConversionSession – Cover-Auswahl")
@MainActor
struct CoverSelectionTests {
    @Test("Entwertete Cover-Suche beginnt keine weitere alte Quelle")
    func invalidatedArtworkStopsBeforeNextSource() async throws {
        let urls = ["alt-a.m4a", "alt-b.m4a"].map { URL(fileURLWithPath: "/tmp/" + $0) }
        let probe = ArtworkLoaderProbe(dataByURL: [:])
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        session.title = "Titel"; session.author = "Autor"
        session.embeddedArtworkLoader = { url in await probe.load(url) }
        await session.importAnalyzedFiles(urls.map { AudioFile(url: $0, startTime: 0, duration: 1, chapterTitle: $0.lastPathComponent) })
        for _ in 0..<200 {
            if await probe.snapshot().started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.snapshot().started)
        session.removeCover()
        await probe.releaseFirstCall()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await probe.snapshot().calls == [urls[0]])
        #expect(!session.isPreparingArtwork)
    }

    @Test("Undo nach Leeren setzt eine unterbrochene Cover-Suche fort")
    func undoRestartsUnfinishedArtwork() async throws {
        let source = URL(fileURLWithPath: "/tmp/undo-cover.m4a")
        let data = try onePixelPNGData()
        let probe = ArtworkLoaderProbe(dataByURL: [source: data])
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        session.title = "Titel"; session.author = "Autor"
        session.embeddedArtworkLoader = { url in await probe.load(url) }
        await session.importAnalyzedFiles([AudioFile(url: source, startTime: 0, duration: 1, chapterTitle: "Kapitel")])
        for _ in 0..<200 {
            if await probe.snapshot().started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.snapshot().started)
        session.removeAllChapters()
        session.undoChapterEdit()
        for _ in 0..<200 {
            if session.embeddedCoverData != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.audioFiles.count == 1)
        #expect(session.embeddedCoverData == data)
        #expect(await probe.snapshot().calls == [source, source])
        await probe.releaseFirstCall()
    }

    @Test("Manuell gewähltes Cover bleibt als unveränderlicher Inhalt erhalten")
    func selectedCoverKeepsContentSnapshot() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cover = directory.appendingPathComponent("cover.png")
        let original = try onePixelPNGData()
        let replacement = try onePixelPNGData(channelValue: 127)
        try original.write(to: cover)
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }

        #expect(session.selectCover(url: cover))
        try replacement.write(to: cover)

        #expect(session.coverPath == cover.path)
        #expect(session.embeddedCoverData == original)
        #expect(FFmpegWrapper.coverSnapshotForConversion(session) == original)
        #expect(FFmpegWrapper.coverSnapshotForConversion(session) != replacement)
        #expect(session.coverImage != nil)
    }

    @Test("Direkter Audio-Drop übernimmt sein eingebettetes Cover")
    func directAudioDropExtractsEmbeddedArtwork() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("mit-cover.m4a")
        let expectedArtwork = try onePixelPNGData()
        try writeAudioWithEmbeddedCover(
            to: audio,
            coverData: expectedArtwork,
            in: directory
        )
        let expectedEmbeddedArtwork = try #require(
            await AudioFile.extractEmbeddedArtwork(from: audio)
        )

        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        let token = session.beginImport()
        let found = try #require(SourceDiscovery.foundFile(at: audio))
        let loaded = await session.loadAudioFiles(from: found, importToken: token)
        session.stageAudioLoadResult(loaded, importToken: token)
        await session.finishImport(token)

        var attempts = 0
        while session.embeddedCoverData == nil, attempts < 200 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.coverImage != nil)
        #expect(session.embeddedCoverData == expectedEmbeddedArtwork)
    }

    /// Regression für den CLI-`--file`-Pfad: Das Cover muss direkt nach dem
    /// Import feststehen — ohne Polling auf eine Hintergrundsuche, weil
    /// `--inspect` und die Konvertierung genau so weiterarbeiten.
    @Test("CLI-Dateiimport bestimmt das eingebettete Cover synchron")
    func fileImportResolvesEmbeddedArtworkSynchronously() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("cli-mit-cover.m4a")
        let expectedArtwork = try onePixelPNGData()
        try writeAudioWithEmbeddedCover(
            to: audio,
            coverData: expectedArtwork,
            in: directory
        )
        let expectedEmbeddedArtwork = try #require(
            await AudioFile.extractEmbeddedArtwork(from: audio)
        )

        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        session.title = "Titel"
        session.author = "Autor"
        session.beginPreparation()
        await session.importFiles([audio])

        // Kein Warten: Der Import ist vorbei, das Cover muss schon da sein und
        // keine Hintergrundsuche mehr laufen.
        #expect(!session.isPreparingArtwork)
        #expect(session.coverImage != nil)
        #expect(session.embeddedCoverData == expectedEmbeddedArtwork)
        #expect(!session.showSelectionUI)
    }

    @Test("Ein verworfener Zusatz-Drop startet die entwertete Artwork-Suche neu")
    func rejectedAdditionalDropRestartsArtworkSearch() async throws {
        let source = URL(fileURLWithPath: "/tmp/bestehendes-kapitel.m4a")
        let artwork = try onePixelPNGData()
        let probe = ArtworkLoaderProbe(dataByURL: [source: artwork])
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        session.title = "Titel"
        session.author = "Autor"
        session.embeddedArtworkLoader = { url in await probe.load(url) }
        let existing = AudioFile(
            url: source,
            startTime: 0,
            duration: 1,
            chapterTitle: "Kapitel"
        )

        await session.importAnalyzedFiles([existing])
        var probeState = await probe.snapshot()
        var attempts = 0
        while !probeState.started, attempts < 200 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
            probeState = await probe.snapshot()
        }
        #expect(probeState.started)

        let token = session.beginImport()
        session.stageProviderLoadFailure(
            position: 1,
            total: 1,
            errorDescription: nil,
            importToken: token
        )
        await session.finishImport(token)

        attempts = 0
        while session.embeddedCoverData == nil, attempts < 200 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        probeState = await probe.snapshot()
        #expect(probeState.calls == [source, source])
        #expect(session.embeddedCoverData == artwork)
        await probe.releaseFirstCall()
    }

    @Test("Eine Auswahl ohne Dateien startet die entwertete Artwork-Suche neu")
    func emptyImportBatchRestartsArtworkSearch() async throws {
        let source = URL(fileURLWithPath: "/tmp/leerer-batch-kapitel.m4a")
        let artwork = try onePixelPNGData()
        let probe = ArtworkLoaderProbe(dataByURL: [source: artwork])
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        session.title = "Titel"
        session.author = "Autor"
        session.embeddedArtworkLoader = { url in await probe.load(url) }
        let existing = AudioFile(
            url: source,
            startTime: 0,
            duration: 1,
            chapterTitle: "Kapitel"
        )

        await session.importAnalyzedFiles([existing])
        var probeState = await probe.snapshot()
        var attempts = 0
        while !probeState.started, attempts < 200 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
            probeState = await probe.snapshot()
        }
        #expect(probeState.started)

        // Das Auswahlfenster wurde bestätigt, hat aber keine Datei geliefert.
        // Dieser Batch hat nichts abzuschließen — die laufende Cover-Suche
        // darf er trotzdem nicht mitnehmen.
        _ = session.beginImport(expectedItemCount: 0)
        #expect(!session.isImporting)

        attempts = 0
        while session.embeddedCoverData == nil, attempts < 200 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        probeState = await probe.snapshot()
        #expect(probeState.calls == [source, source])
        #expect(session.embeddedCoverData == artwork)
        await probe.releaseFirstCall()
    }

    @Test("Ein übersprungener Zusatz-Drop startet die entwertete Artwork-Suche neu")
    func skippedAdditionalDropRestartsArtworkSearch() async throws {
        let source = URL(fileURLWithPath: "/tmp/uebersprungenes-kapitel.m4a")
        let artwork = try onePixelPNGData()
        let probe = ArtworkLoaderProbe(dataByURL: [source: artwork])
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        session.title = "Titel"
        session.author = "Autor"
        session.embeddedArtworkLoader = { url in await probe.load(url) }
        let existing = AudioFile(
            url: source,
            startTime: 0,
            duration: 1,
            chapterTitle: "Kapitel"
        )

        await session.importAnalyzedFiles([existing])
        var probeState = await probe.snapshot()
        var attempts = 0
        while !probeState.started, attempts < 200 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
            probeState = await probe.snapshot()
        }
        #expect(probeState.started)

        // Eine gedroppte Bild- oder Textdatei ist keine Audiodatei: Der Batch
        // wird erfolgreich verbucht, liefert aber keine einzige Datei.
        let token = session.beginImport()
        session.stageAudioLoadResult(.skipped, importToken: token)
        await session.finishImport(token)

        attempts = 0
        while session.embeddedCoverData == nil, attempts < 200 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        probeState = await probe.snapshot()
        #expect(probeState.calls == [source, source])
        #expect(session.embeddedCoverData == artwork)
        await probe.releaseFirstCall()
    }

    @Test("Ein Ordner ohne Cover startet die entwertete Artwork-Suche neu")
    func coverlessFolderDropRestartsArtworkSearch() async throws {
        let source = URL(fileURLWithPath: "/tmp/bestehendes-kapitel-ordner.m4a")
        let artwork = try onePixelPNGData()
        let probe = ArtworkLoaderProbe(dataByURL: [source: artwork])
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        session.title = "Titel"
        session.author = "Autor"
        session.embeddedArtworkLoader = { url in await probe.load(url) }
        let existing = AudioFile(
            url: source,
            startTime: 0,
            duration: 1,
            chapterTitle: "Kapitel"
        )

        await session.importAnalyzedFiles([existing])
        var probeState = await probe.snapshot()
        var attempts = 0
        while !probeState.started, attempts < 200 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
            probeState = await probe.snapshot()
        }
        #expect(probeState.started)

        // Ein Ordner ohne Audiodateien, ohne eingebettetes Cover und ohne
        // Bilddatei: nichts, was die alte Suche ersetzen könnte.
        let token = session.beginImport()
        session.stageScannedFolder(
            .init(
                folderURL: URL(fileURLWithPath: "/tmp/Leerer Ordner"),
                audioFiles: [],
                imageURLs: [],
                embeddedArtwork: nil
            ),
            importToken: token
        )
        await session.finishImport(token)

        attempts = 0
        while session.embeddedCoverData == nil, attempts < 200 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        probeState = await probe.snapshot()
        #expect(probeState.calls == [source, source])
        #expect(session.embeddedCoverData == artwork)
        await probe.releaseFirstCall()
    }

    @Test("Deaktivierte Ordneranalyse liest weder eingebettete noch separate Bilder")
    func folderScanCanSkipArtwork() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("mit-cover.m4a")
        let artwork = try onePixelPNGData()
        try writeAudioWithEmbeddedCover(to: audio, coverData: artwork, in: directory)

        let session = ConversionSession(settings: AudioSettings())
        session.beginPreparation()
        let scanned = await session.scanFolder(directory, analyzeArtwork: false)

        #expect(scanned.audioFiles.count == 1)
        #expect(scanned.imageURLs.isEmpty)
        #expect(scanned.embeddedArtwork == nil)
    }

    @Test("Entferntes Kapitel lässt die Cover-Suche bei verbleibenden Dateien weiterlaufen")
    func artworkSearchContinuesAfterRemovingCandidate() async throws {
        let firstURL = URL(fileURLWithPath: "/tmp/erstes.m4a")
        let secondURL = URL(fileURLWithPath: "/tmp/zweites.m4a")
        let firstArtwork = try onePixelPNGData()
        let secondArtwork = try onePixelPNGData(channelValue: 127)
        let probe = ArtworkLoaderProbe(dataByURL: [
            firstURL: firstArtwork,
            secondURL: secondArtwork
        ])
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        session.title = "Titel"
        session.author = "Autor"
        session.embeddedArtworkLoader = { url in await probe.load(url) }
        let first = AudioFile(
            url: firstURL,
            startTime: 0,
            duration: 1,
            chapterTitle: "Erstes"
        )
        let second = AudioFile(
            url: secondURL,
            startTime: 0,
            duration: 1,
            chapterTitle: "Zweites"
        )

        await session.importAnalyzedFiles([first, second])
        var probeState = await probe.snapshot()
        var attempts = 0
        while !probeState.started, attempts < 200 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
            probeState = await probe.snapshot()
        }
        #expect(probeState.started)
        session.removeChapter(id: first.id)
        await probe.releaseFirstCall()

        attempts = 0
        while session.embeddedCoverData == nil, attempts < 200 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        probeState = await probe.snapshot()
        #expect(probeState.calls == [firstURL, secondURL])
        #expect(session.embeddedCoverData == secondArtwork)
    }
    @Test("Cover bleibt verfügbar, wenn ein weiteres Kapitel derselben Datei erhalten ist")
    func artworkStillBelongsToRemainingChapterOfTheSameFile() async throws {
        let source = URL(fileURLWithPath: "/tmp/gemeinsame-quelle.m4b")
        let cover = try onePixelPNGData()
        let probe = ArtworkLoaderProbe(dataByURL: [source: cover])
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        session.bookMetadata.title = "Titel"
        session.bookMetadata.author = "Autor"
        session.embeddedArtworkLoader = { url in await probe.load(url) }
        let first = AudioFile(url: source, startTime: 0, duration: 1, chapterTitle: "Erstes")
        let second = AudioFile(url: source, startTime: 1, duration: 1, chapterTitle: "Zweites")

        await session.importAnalyzedFiles([first, second])
        for _ in 0..<200 {
            if await probe.snapshot().started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await probe.snapshot().started)
        session.removeChapter(id: first.id)
        await probe.releaseFirstCall()
        for _ in 0..<200 {
            if !session.isPreparingArtwork { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.audioFiles == [second])
        #expect(session.embeddedCoverData == cover)
        #expect(await probe.snapshot().calls == [source])
    }
}
