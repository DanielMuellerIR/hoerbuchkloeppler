import Foundation
import Testing
import Darwin
@testable import HoerbuchkloepplerCore

@Suite("Projektformat und Kapitelbearbeitung")
@MainActor
struct ProjectTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Projekt-Roundtrip erhält Reihenfolge, Abschnitte, Metadaten und Einstellungen")
    func roundTrip() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Quelle.wav")
        try Data([1, 2, 3]).write(to: source)
        let session = ConversionSession(settings: AudioSettings(isMono: false, bitrate: "256k"))
        session.audioFiles = [AudioFile(url: source, startTime: 4, duration: 2, chapterTitle: "Zweiter zuerst"), AudioFile(url: source, startTime: 0, duration: 4, chapterTitle: "Erster zuletzt")]
        session.title = "Buchtitel"; session.narrator = "Sprecher"; session.series = "Reihe"; session.volumeNumber = "2"; session.language = "de"
        session.removeCover()
        let url = root.appendingPathComponent("Buch.hkproject")
        try session.saveProject(to: url)
        let project = try AudiobookProject.read(from: url)
        #expect(project.formatVersion == 1)
        #expect(project.sources.count == 1)
        #expect(project.sources[0].location.isRelative)
        #expect(project.sources[0].location.path == "Quelle.wav")
        let reopened = ConversionSession(settings: AudioSettings())
        try reopened.openProject(from: url)
        #expect(reopened.audioFiles == session.audioFiles)
        #expect(reopened.bookMetadata == session.bookMetadata)
        #expect(reopened.settings == session.settings)
        #expect(reopened.isCoverSuppressed)
        #expect(reopened.projectSourceIssues.isEmpty)
        #expect(!reopened.canUndoChapters)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }

    @Test("Fehlende/geänderte Quellen bleiben auch nach erneutem Speichern sichtbar")
    func sourceChangesRemainVisible() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Quelle.wav")
        try Data([1, 2, 3]).write(to: source)
        let session = ConversionSession(settings: AudioSettings())
        session.audioFiles = [AudioFile(url: source, startTime: 0, duration: 1, chapterTitle: "Alt")]
        let url = root.appendingPathComponent("Buch.hkproject")
        try session.saveProject(to: url)
        try Data([3, 2, 1]).write(to: source)
        try session.openProject(from: url)
        #expect(session.projectSourceIssues.first?.reason == "Quelle wurde verändert")
        session.audioFiles[0].chapterTitle = "Bearbeitet"
        try session.saveProject(to: url)
        try session.openProject(from: url)
        #expect(session.audioFiles[0].chapterTitle == "Bearbeitet")
        #expect(session.projectSourceIssues.count == 1)
        try FileManager.default.removeItem(at: source)
        session.refreshProjectSourceIssues()
        #expect(session.projectSourceIssues.first?.reason == "Quelle fehlt oder ist nicht lesbar")
        try session.saveProject(to: url)
        try session.openProject(from: url)
        #expect(session.projectSourceIssues.count == 1)
    }

    @Test("Asynchrones Speichern/Öffnen hält Hashes an die Dateiidentität gebunden")
    func asyncProjectRoundTrip() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Quelle.wav")
        try Data([1, 2, 3]).write(to: source)
        let session = ConversionSession(settings: AudioSettings(importWorkerLimit: 2))
        session.audioFiles = [AudioFile(url: source, startTime: 0, duration: 1, chapterTitle: "Kapitel")]
        let url = root.appendingPathComponent("Buch.hkproject")
        try await session.saveProjectAsync(to: url)
        let reopened = ConversionSession(settings: AudioSettings())
        try await reopened.openProjectAsync(from: url)
        #expect(reopened.audioFiles == session.audioFiles)
        #expect(reopened.settings.importWorkerLimit == 2)
        #expect(reopened.projectSourceIssues.isEmpty)
        try Data([4, 5, 6]).write(to: source)
        reopened.refreshProjectSourceIssues()
        #expect(reopened.projectSourceIssues.count == 1)
    }

    @Test("Export prüft eine zurückgekehrte Projektquelle und lehnt abweichende Inhalte ab")
    func conversionReverifiesProjectSource() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Quelle.wav")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: source)
        let original = ConversionSession(settings: AudioSettings())
        original.audioFiles = [AudioFile(url: source, startTime: 0, duration: 1, chapterTitle: "Kapitel")]
        let projectURL = root.appendingPathComponent("Buch.hkproject")
        try original.saveProject(to: projectURL)
        try FileManager.default.removeItem(at: source)

        let reopened = ConversionSession(settings: AudioSettings())
        try await reopened.openProjectAsync(from: projectURL)
        #expect(reopened.projectSourceIssues.first?.reason == "Quelle fehlt oder ist nicht lesbar")
        let legacy = ConversionSession(settings: AudioSettings())
        try legacy.openProject(from: projectURL)
        try bytes.write(to: source)

        // Der Zielordner verhindert einen Werkzeugstart nach erfolgreicher Quellenprüfung.
        func plan() -> ConversionPlan {
            FFmpegWrapper.makeConversionPlan(files: reopened.audioFiles, outputURL: root, maxDurationHours: nil)
        }
        #expect(FFmpegWrapper.startVerifiedConversion(session: reopened, plan: plan()) == .rejected("Projektquellen fehlen oder wurden verändert."))
        let directoryError = ConversionOutputError.destinationIsDirectory(root).localizedDescription
        #expect(await FFmpegWrapper.convertAsync(session: reopened, plan: plan()) == .rejected(directoryError))
        #expect(reopened.projectSourceIssues.isEmpty)
        #expect(FFmpegWrapper.convert(session: legacy, outputURL: root) == .rejected(directoryError))

        // Die gleiche Datei mit geänderter mtime darf nach erneuter Inhaltsprüfung passieren.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: source.path)
        #expect(await FFmpegWrapper.convertAsync(session: reopened, plan: plan()) == .rejected(directoryError))
        #expect(reopened.projectSourceIssues.isEmpty)

        try Data([3, 2, 1]).write(to: source, options: .atomic)
        #expect(await FFmpegWrapper.convertAsync(session: reopened, plan: plan()) == .rejected("Projektquellen fehlen oder wurden verändert."))
        #expect(reopened.projectSourceIssues.first?.reason == "Quelle wurde verändert")
    }

    @Test("Verifizierter Export bindet die Projektquelle an die geplante Dateiidentität")
    func projectSourceMustMatchPlannedSnapshot() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Quelle.wav")
        let original = root.appendingPathComponent("Original.wav")
        let output = root.appendingPathComponent("Ausgabe.m4b")
        try Data([1, 2, 3]).write(to: source)
        let session = ConversionSession(settings: AudioSettings())
        session.audioFiles = [AudioFile(url: source, startTime: 0, duration: 1, chapterTitle: "Kapitel")]
        try session.saveProject(to: root.appendingPathComponent("Buch.hkproject"))

        try FileManager.default.moveItem(at: source, to: original)
        try Data([4, 5, 6]).write(to: source)
        let wrongFilePlan = FFmpegWrapper.makeConversionPlan(files: session.audioFiles, outputURL: output, maxDurationHours: nil)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.moveItem(at: original, to: source)

        session.refreshProjectSourceIssues()
        #expect(session.projectSourceIssues.isEmpty)
        #expect(FFmpegWrapper.startVerifiedConversion(session: session, plan: wrongFilePlan) == .rejected("Projektquellen fehlen oder wurden verändert."))
        #expect(session.projectSourceIssues.first?.reason == "Quelle wurde verändert")
        #expect(!session.isConverting && !FileManager.default.fileExists(atPath: output.path))
    }

    @Test("Verifizierter Start verwendet ausschließlich Kapitel des aktuellen Buchs")
    func verifiedStartRejectsObsoleteChapters() {
        let session = ConversionSession(settings: AudioSettings())
        let source = URL(fileURLWithPath: "/tmp/kloeppler-alte-quelle.wav")
        session.audioFiles = [AudioFile(url: source, startTime: 0, duration: 1, chapterTitle: "Alt")]
        let plan = FFmpegWrapper.makeConversionPlan(files: session.audioFiles, outputURL: source, maxDurationHours: nil)
        session.audioFiles[0].chapterTitle = "Neu"
        #expect(FFmpegWrapper.startVerifiedConversion(session: session, plan: plan) == .rejected("Das Hörbuch wurde geändert oder wird bereits bearbeitet. Bitte erneut starten."))
        #expect(FFmpegWrapper.convert(session: session, plan: plan) == .rejected("Das Hörbuch wurde geändert oder wird bereits bearbeitet. Bitte erneut starten."))
        _ = session.beginImport()
        #expect(FFmpegWrapper.convert(session: session, outputURL: source) == .rejected("Das Hörbuch wurde geändert oder wird bereits bearbeitet. Bitte erneut starten."))
        session.cancelImport()
        #expect(!session.isConverting)
    }

    @Test("Ein fremder synchroner Exportplan kann eine fehlende Projektquelle nicht umgehen")
    func synchronousStartRejectsPlanFromAnotherBook() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Quelle.wav")
        let unrelated = root.appendingPathComponent("Andere Quelle.wav")
        try Data([1]).write(to: source)
        try Data([2]).write(to: unrelated)
        let session = ConversionSession(settings: AudioSettings())
        session.audioFiles = [AudioFile(url: source, startTime: 0, duration: 1, chapterTitle: "Kapitel")]
        try session.saveProject(to: root.appendingPathComponent("Buch.hkproject"))
        try FileManager.default.removeItem(at: source)
        session.refreshProjectSourceIssues()
        #expect(session.projectSourceIssues.first?.reason == "Quelle fehlt oder ist nicht lesbar")

        let unrelatedFile = AudioFile(url: unrelated, startTime: 0, duration: 1, chapterTitle: "Ein anderes Kapitel")
        let plan = FFmpegWrapper.makeConversionPlan(files: [unrelatedFile], outputURL: root, maxDurationHours: nil)
        #expect(FFmpegWrapper.convert(session: session, plan: plan) == .rejected("Das Hörbuch wurde geändert oder wird bereits bearbeitet. Bitte erneut starten."))
        #expect(session.projectSourceIssues.first?.reason == "Quelle fehlt oder ist nicht lesbar")
    }

    @Test("Ein abgebrochener Öffnen-Aufruf erhält die vorige Session")
    func cancelledAsyncOpenKeepsSession() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Buch.hkproject")
        let original = ConversionSession(settings: AudioSettings())
        original.title = "Anderes Buch"
        try original.saveProject(to: projectURL)

        let session = ConversionSession(settings: AudioSettings())
        session.title = "Behalten"
        let opening = Task { try await session.openProjectAsync(from: projectURL) }
        opening.cancel()
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(session.title == "Behalten")
        #expect(session.loadedProjectURL == nil)
    }

    @Test("Teilen, Zusammenführen, Nummerieren und Undo/Redo erhalten Zeitabschnitte")
    func editing() {
        let source = URL(fileURLWithPath: "/tmp/source.wav")
        let session = ConversionSession(settings: AudioSettings())
        let first = AudioFile(url: source, startTime: 3, duration: 10, chapterTitle: "Kapitel")
        session.audioFiles = [first]; session.title = "Buch"
        session.splitChapter(id: first.id, at: 7)
        #expect(session.audioFiles.map(\.startTime) == [3, 7])
        #expect(session.audioFiles.map(\.duration) == [4, 6])
        #expect(session.canMergeChapterWithNext(id: session.audioFiles[0].id))
        session.mergeChapterWithNext(id: session.audioFiles[0].id)
        #expect(session.audioFiles.count == 1)
        #expect(session.audioFiles[0].duration == 10)
        session.undoChapterEdit()
        #expect(session.audioFiles.count == 2)
        session.redoChapterEdit()
        #expect(session.audioFiles.count == 1)
        session.renameChapters(ids: Set(session.audioFiles.map(\.id)), prefix: "Teil", startingAt: 5)
        #expect(session.audioFiles[0].chapterTitle == "Teil 5")
        session.undoChapterEdit()
        #expect(session.audioFiles[0].chapterTitle == "Kapitel")
        session.audioFiles = []
        session.undoChapterEdit()
        #expect(session.title == "Buch")
        #expect(session.audioFiles.count == 1)
    }

    @Test("Zusammenführen ist nur für lückenlose Abschnitte derselben Quelle möglich")
    func mergeAvailabilityMatchesCorePreconditions() {
        let session = ConversionSession(settings: AudioSettings())
        let firstURL = URL(fileURLWithPath: "/tmp/erstes.wav")
        let secondURL = URL(fileURLWithPath: "/tmp/zweites.wav")
        let first = AudioFile(url: firstURL, startTime: 0, duration: 1, chapterTitle: "A")
        let otherSource = AudioFile(url: secondURL, startTime: 1, duration: 1, chapterTitle: "B")
        session.audioFiles = [first, otherSource]
        #expect(!session.canMergeChapterWithNext(id: first.id))

        let gap = AudioFile(url: firstURL, startTime: 2, duration: 1, chapterTitle: "C")
        session.audioFiles = [first, gap]
        #expect(!session.canMergeChapterWithNext(id: first.id))
    }

    @Test("Undo einer Kapiteländerung erhält zwischenzeitlich getippte Metadaten")
    func undoKeepsLaterMetadata() {
        let source = URL(fileURLWithPath: "/tmp/source.wav")
        let session = ConversionSession(settings: AudioSettings())
        let first = AudioFile(url: source, startTime: 0, duration: 10, chapterTitle: "Kapitel")
        session.audioFiles = [first]
        session.splitChapter(id: first.id, at: 5)
        // Nach der Kapiteländerung werden Metadaten eingegeben …
        session.title = "Nachträglich"; session.narrator = "Sprecherin"
        // … und ein Undo darf nur die Kapitel zurücknehmen.
        session.undoChapterEdit()
        #expect(session.audioFiles.count == 1)
        #expect(session.title == "Nachträglich")
        #expect(session.narrator == "Sprecherin")
        session.redoChapterEdit()
        #expect(session.audioFiles.count == 2)
        #expect(session.title == "Nachträglich")
        // Das Entfernen des letzten Kapitels löscht die Metadaten; hier stellt
        // Undo sie weiterhin aus dem Snapshot wieder her.
        session.audioFiles = []
        #expect(session.title.isEmpty)
        session.undoChapterEdit()
        #expect(session.audioFiles.count == 2)
        #expect(session.title == "Nachträglich")
    }

    @Test("Zeichenweise Titeleingabe belegt nur einen Undo-Schritt")
    func chapterTitleTypingCoalesces() {
        let source = URL(fileURLWithPath: "/tmp/source.wav")
        let session = ConversionSession(settings: AudioSettings())
        let first = AudioFile(url: source, startTime: 0, duration: 10, chapterTitle: "Kapitel")
        session.audioFiles = [first]
        for typed in ["N", "Ne", "Neu"] { session.audioFiles[0].chapterTitle = typed }
        session.undoChapterEdit()
        #expect(session.audioFiles[0].chapterTitle == "Kapitel")
        // Danach liegt nur noch der Eintrag der leeren Ausgangsliste vor.
        session.undoChapterEdit()
        #expect(session.audioFiles.isEmpty)
        #expect(!session.canUndoChapters)
    }

    @Test("Ältere Projektdateien ohne neue Felder werden tolerant gelesen")
    func tolerantDecoding() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("alt.hkproject")
        try Data(#"{"sources":[],"sections":[],"metadata":{"title":"Alt"},"settings":{}}"#.utf8).write(to: url)
        let project = try AudiobookProject.read(from: url)
        #expect(project.formatVersion == AudiobookProject.currentVersion)
        #expect(project.metadata.title == "Alt")
        #expect(project.metadata.genre == "Hörbuch")
        #expect(project.metadata.language.isEmpty)
        #expect(!project.coverSuppressed)
        #expect(project.coverData == nil)
    }

    @Test("Fremde Projektversion liefert die dokumentierte Meldung")
    func foreignVersionMessage() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("zukunft.hkproject")
        try Data(#"{"formatVersion":2,"chapters":[]}"#.utf8).write(to: url)
        do {
            _ = try AudiobookProject.read(from: url)
            Issue.record("Fremde Version wurde akzeptiert")
        } catch let error as ProjectError {
            #expect(error.errorDescription == "Projektversion 2 wird nicht unterstützt.")
        }
    }

    @Test("Nachimport hängt sortierte neue Kapitel an die manuelle Reihenfolge")
    func appendPreservesOrder() async {
        let session = ConversionSession(settings: AudioSettings())
        let files = ["B", "A", "D", "C"].map { AudioFile(url: URL(fileURLWithPath: "/tmp/\($0).wav"), startTime: 0, duration: 1, chapterTitle: $0) }
        session.audioFiles = Array(files.prefix(2))
        session.title = "Buch"; session.author = "Autor"
        await session.processIncomingFiles(Array(files.suffix(2)), skipCoverExtraction: true)
        #expect(session.audioFiles.map(\.chapterTitle) == ["B", "A", "C", "D"])
        session.moveChapters(from: IndexSet(integer: 0), to: 4)
        #expect(session.audioFiles.map(\.chapterTitle) == ["A", "C", "D", "B"])
    }

    @Test("Fingerprints lehnen FIFO ohne blockierendes Öffnen ab")
    func rejectsFIFO() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("pipe.wav")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { _ = try ProjectSource.fingerprint(fifo) }
    }

    @Test("Projektdateien werden nur als reguläre Datei bis 48 MiB gelesen")
    func rejectsSpecialAndOversizedProjectFiles() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("Warteschlange.hkproject")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        #expect { _ = try AudiobookProject.read(from: fifo) } throws: { error in
            error.localizedDescription.contains("keine reguläre Datei")
        }

        let oversized = root.appendingPathComponent("Gross.hkproject")
        try Data().write(to: oversized)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 48 * 1024 * 1024 + 1)
        try handle.close()
        #expect { _ = try AudiobookProject.read(from: oversized) } throws: { error in
            error.localizedDescription == "Projektdatei überschreitet 48 MiB."
        }
    }

    @Test("Projekt lädt nur in Vorschau und Kapitelmetadaten darstellbare Zeitwerte")
    func projectSectionTimesMustFitIntegerTimebases() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Zeiten.hkproject")
        let source = root.appendingPathComponent("Quelle.wav")
        try Data([1]).write(to: source)
        let session = ConversionSession(settings: AudioSettings())
        session.audioFiles = [AudioFile(url: source, startTime: 0, duration: 1, chapterTitle: "Kapitel")]
        var project = try session.makeProject(at: url)
        let section = try #require(project.sections.first)
        let limit = Double(Int64.max)

        let invalidTimes: [[(start: Double, duration: Double)]] = [
            [(1e20, 1)], [(limit / 600, 1)], [(0, limit / 1000)], [(0, 6e15), (0, 6e15)]
        ]
        for times in invalidTimes {
            project.sections = times.map { time in
                ProjectSection(id: UUID(), sourceID: section.sourceID, start: time.start, duration: time.duration, title: section.title)
            }
            try project.write(to: url)
            #expect { _ = try AudiobookProject.read(from: url) } throws: { error in
                error.localizedDescription == "Kapitelzeiten oder Gesamtdauer des Projekts sind ungültig."
            }
        }

        project.sections = [ProjectSection(id: section.id, sourceID: section.sourceID,
            start: 10_000_000_000, duration: 1e15, title: section.title)]
        try project.write(to: url)
        #expect(try AudiobookProject.read(from: url).sections.first?.duration == 1e15)
    }

    @Test("Externe Quellen bleiben eindeutig absolut, ungültiges Umordnen bleibt folgenlos")
    func externalLocationsAndInvalidMoves() {
        let location = ProjectLocation(url: URL(fileURLWithPath: "/other/source.wav"), projectURL: URL(fileURLWithPath: "/books/test.hkproject"))
        #expect(!location.isRelative)
        #expect(location.resolve(from: URL(fileURLWithPath: "/moved/test.hkproject")).path == "/other/source.wav")
        let session = ConversionSession(settings: AudioSettings())
        let file = AudioFile(url: URL(fileURLWithPath: "/tmp/test.wav"), startTime: 0, duration: 1, chapterTitle: "Kapitel")
        session.audioFiles = [file]
        session.moveChapters(from: IndexSet(integer: 99), to: 0)
        #expect(session.audioFiles == [file])
    }

    @Test("Unbekannte Projektversion verändert vorhandene Session nicht")
    func rejectsFutureVersion() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = ConversionSession(settings: AudioSettings())
        session.title = "Behalten"
        var project = try session.makeProject(at: root)
        project.formatVersion = 99
        let url = root.appendingPathComponent("future.hkproject")
        try project.write(to: url)
        #expect(throws: (any Error).self) { try session.openProject(from: url) }
        #expect(session.title == "Behalten")
    }

    @Test("Ein Finder-Tag an der Quelle gilt nicht als Inhaltsänderung")
    func metadataOnlySourceChangeIsNoContentChange() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Quelle.wav")
        try Data([1, 2, 3]).write(to: source)
        let session = ConversionSession(settings: AudioSettings())
        session.audioFiles = [AudioFile(url: source, startTime: 0, duration: 1, chapterTitle: "Kapitel")]
        let url = root.appendingPathComponent("Buch.hkproject")
        try session.saveProject(to: url)

        // Wie in der GUI: Das asynchrone Öffnen prüft die Quellen im Hintergrund.
        let reopened = ConversionSession(settings: AudioSettings())
        try await reopened.openProjectAsync(from: url)
        #expect(reopened.projectSourceIssues.isEmpty)

        // Ein Finder-Tag schreibt nur ein erweitertes Attribut. Inhalt und
        // Änderungszeit bleiben gleich, allein die Statuszeit (ctime) steigt.
        var tag: [UInt8] = [0x41]
        #expect(setxattr(source.path, "com.apple.metadata:_kMDItemUserTags", &tag, tag.count, 0, 0) == 0)

        try await reopened.verifyProjectSources()
        #expect(reopened.projectSourceIssues.isEmpty)
        // Auch der zweite Aufruf darf nicht kippen: Der Fehlalarm war früher
        // selbsterhaltend, weil nie neu gehasht wurde.
        reopened.refreshProjectSourceIssues()
        #expect(reopened.projectSourceIssues.isEmpty)
    }

    @Test("Gleich großer neuer Inhalt bleibt auch mit wiederhergestellter mtime erkennbar")
    func sourceRewriteWithRestoredModificationTime() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Quelle.wav")
        try Data([1, 2, 3]).write(to: source)
        let session = ConversionSession(settings: AudioSettings())
        session.audioFiles = [AudioFile(url: source, startTime: 0, duration: 1, chapterTitle: "Kapitel")]
        try session.saveProject(to: root.appendingPathComponent("Buch.hkproject"))
        let plan = FFmpegWrapper.makeConversionPlan(files: session.audioFiles, outputURL: root, maxDurationHours: nil)

        let handle = try FileHandle(forWritingTo: source)
        defer { try? handle.close() }
        var before = stat()
        try #require(fstat(handle.fileDescriptor, &before) == 0)
        try handle.write(contentsOf: Data([3, 2, 1]))
        let originalTimes = [before.st_atimespec, before.st_mtimespec]
        let timeUpdate = originalTimes.withUnsafeBufferPointer { futimens(handle.fileDescriptor, $0.baseAddress) }
        try #require(timeUpdate == 0)
        var after = stat()
        try #require(fstat(handle.fileDescriptor, &after) == 0)
        let old = FileSystemIdentity(stat: before)
        let new = FileSystemIdentity(stat: after)
        try #require(old.matchesContentSnapshot(new) && old != new)

        let rejection = ConversionStartResult.rejected("Projektquellen fehlen oder wurden verändert.")
        #expect(FFmpegWrapper.startVerifiedConversion(session: session, plan: plan) == rejection)
        #expect(FFmpegWrapper.convert(session: session, plan: plan) == rejection)
        try await session.verifyProjectSources()
        #expect(session.projectSourceIssues.first?.reason == "Quelle wurde verändert")
    }

    @Test("Ein unterbrochenes Speichern meldet sich, statt still nichts zu tun")
    func interruptedAsyncSaveReportsInsteadOfSilence() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Quelle.wav")
        // Bewusst groß: Das Speichern hasht die Quelle außerhalb des Main Actors,
        // und dieser Test braucht dafür ein Zeitfenster, das deutlich über der
        // Einplanungsdauer eines Main-Actor-Sprungs liegt.
        try Data(count: 64 * 1024 * 1024).write(to: source)
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        session.audioFiles = [AudioFile(url: source, startTime: 0, duration: 1, chapterTitle: "Kapitel")]
        let url = root.appendingPathComponent("Buch.hkproject")

        let before = session.projectOperation
        let save = Task { try await session.saveProjectAsync(to: url) }
        // Warten, bis das Speichern seinen Vorgang angemeldet hat und beim
        // Hashen außerhalb des Main Actors hängt.
        let deadline = ContinuousClock.now + .seconds(5)
        while session.projectOperation == before, ContinuousClock.now < deadline {
            await Task.yield()
        }
        guard session.projectOperation != before else {
            Issue.record("Speichern hat seinen Vorgang nicht innerhalb von 5 Sekunden angemeldet")
            save.cancel()
            return
        }
        // Genau hier zieht ein Drop dazwischen: `beginImport` vergibt eine neue
        // Vorgangskennung. Zwischen Prüfung und Aufruf liegt kein `await`, der
        // Zeitpunkt ist also fest.
        _ = session.beginImport()

        await #expect {
            try await save.value
        } throws: { error in
            error.localizedDescription
                == "Das Speichern wurde durch eine andere Aktion unterbrochen; bitte erneut speichern."
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Bereits geschriebener Projektstand meldet spätere Änderungen", arguments: [false, true])
    func lateChangeAfterAsyncSave(reset: Bool) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Quelle.wav")
        let url = root.appendingPathComponent("Buch.hkproject")
        try Data([1, 2, 3]).write(to: source)
        let session = ConversionSession(settings: AudioSettings())
        session.audioFiles = [AudioFile(url: source, startTime: 0, duration: 1, chapterTitle: "Alt")]

        let expectedMessage = reset
            ? "Die Projektdatei wurde geschrieben. Eine andere Aktion hat inzwischen das aktive Projekt verändert."
            : "Die Projektdatei enthält den Stand vor den letzten Änderungen. Bitte erneut speichern."
        await #expect {
            try await session.saveProjectAsync(to: url) { project, destination in
                try project.write(to: destination)
                await MainActor.run {
                    if reset { session.resetSession() }
                    else { session.audioFiles[0].chapterTitle = "Neu" }
                }
            }
        } throws: { error in
            error.localizedDescription == expectedMessage
        }
        #expect(try AudiobookProject.read(from: url).sections[0].title == "Alt")
        if reset {
            #expect(session.loadedProjectURL == nil && session.audioFiles.isEmpty)
        } else {
            #expect(session.loadedProjectURL == url && session.audioFiles[0].chapterTitle == "Neu")
            try Data([4, 5, 6]).write(to: source, options: .atomic)
            let output = root.appendingPathComponent("Ausgabe.m4b")
            let plan = FFmpegWrapper.makeConversionPlan(files: session.audioFiles, outputURL: output, maxDurationHours: nil)
            #expect(FFmpegWrapper.startVerifiedConversion(session: session, plan: plan) == .rejected("Projektquellen fehlen oder wurden verändert."))
        }
    }
}
