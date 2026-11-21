import Foundation
import Testing
@testable import HoerbuchkloepplerCore

@Suite("Atomarer Import und Importabbruch")
@MainActor
struct ImportLifecycleTests {
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

    @Test("Ein Reset räumt auch Phase und fertige Ausgaben des Vorlaufs ab")
    func resetClearsCompleteRunState() {
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        session.conversionPhase = "Buchlautheit messen"
        session.completedOutputURLs = [URL(fileURLWithPath: "/tmp/Buch.m4b")]
        session.progress = 0.5
        session.lastConversionSucceeded = true

        session.resetSession()

        #expect(session.conversionPhase == "Bereit")
        #expect(session.completedOutputURLs.isEmpty)
        #expect(session.conversionStatus == "Bereit")
        #expect(session.progress == 0.0)
        #expect(session.lastConversionSucceeded == nil)
        #expect(!session.isConverting)
        #expect(!session.showOverlay)
        #expect(session.segmentProgress.isEmpty)
    }

    @Test("Der Start-Initialisierer setzt einen vollständigen Laufzustand")
    func startingRunStateUsesFreshDefaults() {
        let state = ConversionRunState(startingWith: "Konvertierung läuft")

        #expect(state.isConverting)
        #expect(state.showOverlay)
        #expect(state.status == "Konvertierung läuft")
        #expect(state.phase == "Konvertierung läuft")
        #expect(state.completedOutputs.isEmpty)
        #expect(state.succeeded == nil)
        #expect(state.progress == 0.0)
        #expect(state.segments.isEmpty)
    }

    @Test("Ein abgebrochener Batch liefert ein Ergebnis je Eingabedatei")
    func cancelledBatchReturnsOneResultPerInput() async {
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        session.beginPreparation()
        // Genau die Lage nach SIGINT in der CLI: Der Vorbereitungskontext ist
        // entwertet, bevor die Analyse überhaupt anläuft.
        _ = session.cancelPreparation()

        let files = (1...3).map { index -> FoundFile in
            let url = URL(fileURLWithPath: "/tmp/abgebrochen-\(index).m4a")
            return FoundFile(source: url, resolved: url)
        }
        let results = await session.loadAudioFiles(from: files)

        // Beide Frontends zählen ihre `finishImport`-Aufrufe über die Ergebnisse.
        #expect(results.count == files.count)
        #expect(results.allSatisfy { if case .cancelled = $0 { return true } else { return false } })
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

    /// Ordner plus eine Datei daraus in einem Drop liefern denselben Pfad
    /// zweimal. Die Zwei-Namen-Meldung nennte hier zweimal denselben Namen und
    /// sagte dem Nutzer nicht, was tatsächlich passiert ist.
    @Test("Ein mehrfach gelieferter Pfad wird als Doppelübergabe gemeldet")
    func repeatedProviderPathIsReportedAsDuplicateDelivery() async {
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        let file = AudioFile(
            url: URL(fileURLWithPath: "/tmp/Kapitel 1.mp3"),
            startTime: 0,
            duration: 1,
            chapterTitle: "Eins"
        )

        await session.processIncomingFiles([file, file], skipCoverExtraction: true)

        #expect(session.audioFiles.count == 1)
        #expect(session.eventLogs.contains {
            $0.message.contains("Kapitel 1.mp3 wurde mehrfach übergeben")
        })
        #expect(!session.eventLogs.contains {
            $0.message.contains("lesen dieselbe Audiodatei")
        })
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

    @Test("Ein Provider-Ladefehler verwirft erfolgreiche Nachbarn mit Positionsangabe")
    func providerLoadFailureRejectsWholeBatch() async {
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        let token = session.beginImport(expectedItemCount: 2)
        let accepted = AudioFile(
            url: URL(fileURLWithPath: "/tmp/akzeptiert.mp3"),
            startTime: 0,
            duration: 1,
            chapterTitle: "Akzeptiert"
        )
        session.stageAudioLoadResult(
            .success(files: [accepted], warnings: []),
            importToken: token
        )
        await session.finishImport(token)
        session.stageProviderLoadFailure(
            position: 2,
            total: 2,
            errorDescription: "Datei nicht verfügbar",
            importToken: token
        )
        await session.finishImport(token)

        #expect(session.audioFiles.isEmpty)
        #expect(session.lastImportFailures.count == 1)
        #expect(session.importErrorMessage?.contains("Drop-Element 2 von 2") == true)
        #expect(session.importErrorMessage?.contains("Datei nicht verfügbar") == true)
        #expect(!session.isImporting)
    }

    @Test("Ein verworfener Zusatz-Drop erhält die bestehende CLI-Ordnerbindung")
    func rejectedAdditionalDropPreservesCLIFolder() async {
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        session.title = "Buch"
        session.author = "Autor"
        let folder = URL(fileURLWithPath: "/tmp/vorhandenes-buch")
        let existing = AudioFile(
            url: folder.appendingPathComponent("01.mp3"),
            startTime: 0,
            duration: 1,
            chapterTitle: "Kapitel"
        )
        await session.applyScannedFolder(.init(
            folderURL: folder,
            audioFiles: [existing],
            imageURLs: [],
            embeddedArtwork: nil
        ))
        #expect(session.cliFolderIfRepresentable == folder)

        let token = session.beginImport()
        session.stageProviderLoadFailure(
            position: 1,
            total: 1,
            errorDescription: nil,
            importToken: token
        )
        await session.finishImport(token)

        #expect(session.audioFiles.map(\.id) == [existing.id])
        #expect(session.cliFolderIfRepresentable == folder)

        let cancelledToken = session.beginImport()
        session.stageAudioLoadResult(.cancelled, importToken: cancelledToken)
        await session.finishImport(cancelledToken)
        #expect(session.audioFiles.map(\.id) == [existing.id])
        #expect(session.cliFolderIfRepresentable == folder)
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

    @Test("Headless-Import öffnet auch bei einem MediaInfo-Fehler keine Auswahl")
    func headlessMetadataFailureDoesNotRequestSelection() async {
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        let token = session.beginImport(allowsSelectionUI: false)
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

        #expect(!session.showSelectionUI)
    }

    @Test("Ein Import mit festen Buchfeldern entfernt alte Kandidaten")
    func completedMetadataClearsStaleCandidates() async {
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        session.title = "Fest"
        session.author = "Fest"
        session.titleCandidates = [TagCandidate(type: "Alt", key: "Title", value: "Alt")]
        session.authorCandidates = [TagCandidate(type: "Alt", key: "Artist", value: "Alt")]
        let token = session.beginImport()
        let file = AudioFile(
            url: URL(fileURLWithPath: "/tmp/fest-\(UUID().uuidString).mp3"),
            startTime: 0,
            duration: 1,
            chapterTitle: "Fest"
        )

        await session.processIncomingFiles(
            [file],
            skipCoverExtraction: true,
            importToken: token
        )
        await session.finishImport(token)

        #expect(session.titleCandidates.isEmpty)
        #expect(session.authorCandidates.isEmpty)
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
