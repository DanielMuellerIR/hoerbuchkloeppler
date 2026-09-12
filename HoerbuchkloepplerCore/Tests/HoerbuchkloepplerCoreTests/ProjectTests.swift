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

        // Wie in der GUI: Das asynchrone Öffnen wärmt den Fingerprint-Speicher
        // außerhalb des Main Actors vor.
        let reopened = ConversionSession(settings: AudioSettings())
        try await reopened.openProjectAsync(from: url)
        #expect(reopened.projectSourceIssues.isEmpty)

        // Ein Finder-Tag schreibt nur ein erweitertes Attribut. Inhalt und
        // Änderungszeit bleiben gleich, allein die Statuszeit (ctime) steigt.
        var tag: [UInt8] = [0x41]
        #expect(setxattr(source.path, "com.apple.metadata:_kMDItemUserTags", &tag, tag.count, 0, 0) == 0)

        reopened.refreshProjectSourceIssues()
        #expect(reopened.projectSourceIssues.isEmpty)
        // Auch der zweite Aufruf darf nicht kippen: Der Fehlalarm war früher
        // selbsterhaltend, weil nie neu gehasht wurde.
        reopened.refreshProjectSourceIssues()
        #expect(reopened.projectSourceIssues.isEmpty)
    }

    @Test("Ein unterbrochenes Speichern meldet sich, statt still nichts zu tun")
    func interruptedAsyncSaveReportsInsteadOfSilence() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Quelle.wav")
        // Bewusst groß: Der Prewarm hasht die Quelle außerhalb des Main Actors,
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
}
