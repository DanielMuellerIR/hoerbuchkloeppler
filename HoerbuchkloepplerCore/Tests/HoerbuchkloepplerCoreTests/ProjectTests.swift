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

    @Test("Teilen, Zusammenführen, Nummerieren und Undo/Redo erhalten Zeitabschnitte")
    func editing() {
        let source = URL(fileURLWithPath: "/tmp/source.wav")
        let session = ConversionSession(settings: AudioSettings())
        let first = AudioFile(url: source, startTime: 3, duration: 10, chapterTitle: "Kapitel")
        session.audioFiles = [first]; session.title = "Buch"
        session.splitChapter(id: first.id, at: 7)
        #expect(session.audioFiles.map(\.startTime) == [3, 7])
        #expect(session.audioFiles.map(\.duration) == [4, 6])
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
}
