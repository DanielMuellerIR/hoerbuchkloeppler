import Foundation
import AppKit

struct ChapterEditSnapshot {
    var files: [AudioFile]
    var metadata: BookMetadata
    var coverData: Data?
    var coverPath: String?
    var coverSuppressed: Bool
}

@MainActor
extension ConversionSession {
    public var bookMetadata: BookMetadata {
        get {
            var value = BookMetadata()
            value.title = title; value.author = author; value.genre = genre
            value.narrator = narrator; value.series = series
            value.volumeNumber = volumeNumber; value.language = language
            return value
        }
        set {
            title = newValue.title; author = newValue.author; genre = newValue.genre
            narrator = newValue.narrator; series = newValue.series
            volumeNumber = newValue.volumeNumber; language = newValue.language
        }
    }

    public func makeProject(at url: URL) throws -> AudiobookProject {
        var sources: [ProjectSource] = []
        var sections: [ProjectSection] = []
        var ids: [URL: UUID] = [:]
        for file in audioFiles {
            let id: UUID
            if let existing = ids[file.sourceURL] { id = existing }
            else {
                id = UUID(); ids[file.sourceURL] = id
                // `resolve` liefert standardisierte URLs; die Quell-URL deshalb
                // ebenso normalisieren, sonst findet ein Pfad mit `..` oder
                // doppeltem Schrägstrich seinen Fingerprint nicht wieder.
                let prior = loadedProjectURL.flatMap { loadedURL in
                    projectSources.first { $0.location.resolve(from: loadedURL) == file.sourceURL.standardizedFileURL }
                }
                sources.append(ProjectSource(id: id,
                    location: ProjectLocation(url: file.sourceURL, projectURL: url),
                    readLocation: ProjectLocation(url: file.url, projectURL: url),
                    sha256: try prior?.sha256 ?? projectFingerprints.fingerprint(file.url)))
            }
            sections.append(ProjectSection(id: file.id, sourceID: id, start: file.startTime, duration: file.duration, title: file.chapterTitle))
        }
        return AudiobookProject(sources: sources, sections: sections, metadata: bookMetadata,
            settings: settings, coverData: embeddedCoverData ?? coverImage?.tiffRepresentation,
            coverSuppressed: isCoverSuppressed)
    }

    public func saveProject(to url: URL) throws {
        refreshProjectSourceIssues()
        let project = try makeProject(at: url)
        try project.write(to: url)
        projectSources = project.sources; loadedProjectURL = url
        refreshProjectSourceIssues()
    }

    public func openProject(from url: URL) throws {
        guard !isConverting else { throw ProjectError.invalid("Während einer Konvertierung kann kein Projekt geöffnet werden.") }
        try applyProject(AudiobookProject.read(from: url), from: url)
    }

    private func applyProject(_ project: AudiobookProject, from url: URL) throws {
        guard !isConverting else { throw ProjectError.invalid("Während einer Konvertierung kann kein Projekt geöffnet werden.") }
        var files: [AudioFile] = []
        let sources = Dictionary(uniqueKeysWithValues: project.sources.map { ($0.id, $0) })
        for section in project.sections {
            guard let source = sources[section.sourceID] else { continue }
            var file = AudioFile(foundFile: FoundFile(source: source.location.resolve(from: url), resolved: source.readLocation.resolve(from: url)), startTime: section.start, duration: section.duration, chapterTitle: section.title)
            file.id = section.id
            files.append(file)
        }
        // Erst vollständig dekodieren, danach bestehenden Zustand ersetzen.
        resetSession()
        audioFiles = files
        bookMetadata = project.metadata
        settings = project.settings.normalized()
        if project.coverSuppressed { removeCover() }
        else { embeddedCoverData = project.coverData; coverImage = project.coverData.flatMap(CoverArtwork.preview(from:)) }
        projectSources = project.sources; loadedProjectURL = url
        undoChapters = []; redoChapters = []; updateHistoryAvailability()
        refreshProjectSourceIssues()
    }

    public func openProjectAsync(from url: URL) async throws {
        let operation = UUID(); projectOperation = operation
        let store = projectFingerprints
        let project = try await Task.detached {
            let project = try AudiobookProject.read(from: url)
            for source in project.sources { _ = try? store.fingerprint(source.readLocation.resolve(from: url)) }
            return project
        }.value
        // Ein zwischenzeitlicher Import oder ein neueres Öffnen hat diesen
        // Vorgang ersetzt. Das still zu schlucken hieße: Das Projekt öffnet
        // sich einfach nicht, ohne dass jemand erfährt warum.
        guard projectOperation == operation else {
            throw ProjectError.invalid("Das Öffnen wurde durch eine andere Aktion unterbrochen; bitte erneut öffnen.")
        }
        try applyProject(project, from: url)
    }

    public func saveProjectAsync(to url: URL) async throws {
        let operation = UUID(); projectOperation = operation
        let files = audioFiles
        let store = projectFingerprints
        await Task.detached {
            for file in files { _ = try? store.fingerprint(file.url) }
        }.value
        // Sonst hielte der Nutzer das Projekt für gespeichert, obwohl nichts
        // geschrieben wurde — der Konfliktfall eine Zeile weiter meldet sich
        // aus demselben Grund.
        guard projectOperation == operation else {
            throw ProjectError.invalid("Das Speichern wurde durch eine andere Aktion unterbrochen; bitte erneut speichern.")
        }
        guard files == audioFiles else { throw ProjectError.invalid("Kapitel wurden während des Speicherns verändert; bitte erneut speichern.") }
        try saveProject(to: url)
    }

    public func refreshProjectSourceIssues() {
        guard let url = loadedProjectURL else { projectSourceIssues = []; return }
        // Wie in `makeProject`: beide Seiten standardisiert vergleichen, damit
        // eine veränderte Quelle nicht wegen Schreibweise des Pfads unbemerkt bleibt.
        let activeURLs = Set(audioFiles.map { $0.sourceURL.standardizedFileURL })
        projectSourceIssues = projectSources.compactMap { source in
            let visible = source.location.resolve(from: url)
            guard activeURLs.contains(visible) else { return nil }
            let readURL = source.readLocation.resolve(from: url)
            let reason: String
            do {
                guard visible.resolvingSymlinksInPath() == readURL.resolvingSymlinksInPath() else {
                    return ProjectSourceIssue(id: source.id, path: visible.path, reason: "Verknüpfung wurde verändert")
                }
                guard FFmpegWrapper.fileSystemIdentity(at: readURL, followSymlink: true) != nil else {
                    return ProjectSourceIssue(id: source.id, path: visible.path, reason: "Quelle fehlt oder ist nicht lesbar")
                }
                if projectFingerprints.changedSinceLastRead(readURL) {
                    return ProjectSourceIssue(id: source.id, path: visible.path, reason: "Quelle wurde verändert")
                }
                if try projectFingerprints.fingerprint(readURL) == source.sha256 { return nil }
                reason = "Quelle wurde verändert"
            } catch { reason = "Quelle fehlt oder ist nicht lesbar" }
            return ProjectSourceIssue(id: source.id, path: visible.path, reason: reason)
        }
    }

    func recordChapterEdit(previous: [AudioFile]) {
        guard !restoringChapters, previous != audioFiles else { return }
        // Das Kapiteltitel-Feld schreibt bei jedem Tastendruck in `audioFiles`.
        // Folgt eine Titeländerung desselben Kapitels direkt auf eine weitere
        // Titeländerung desselben Kapitels, bleibt der ältere Undo-Eintrag
        // stehen: Ein Undo nimmt dann den ganzen getippten Titel zurück statt
        // ein einzelnes Zeichen, und die Historie füllt sich nicht mit Zeichen.
        if let last = undoChapters.last,
           let edited = Self.singleTitleEdit(from: previous, to: audioFiles),
           Self.singleTitleEdit(from: last.files, to: previous) == edited {
            redoChapters.removeAll()
            updateHistoryAvailability()
            return
        }
        undoChapters.append(chapterSnapshot(files: previous))
        if undoChapters.count > 100 { undoChapters.removeFirst() }
        redoChapters.removeAll()
        updateHistoryAvailability()
    }

    func updateHistoryAvailability() {
        canUndoChapters = !undoChapters.isEmpty; canRedoChapters = !redoChapters.isEmpty
    }

    /// Liefert die Kapitel-ID, wenn sich beide Listen ausschließlich im Titel
    /// genau eines Kapitels unterscheiden; sonst `nil`.
    static func singleTitleEdit(from old: [AudioFile], to new: [AudioFile]) -> UUID? {
        guard old.count == new.count else { return nil }
        var changed: UUID?
        for (before, after) in zip(old, new) where before != after {
            var retitled = before
            retitled.chapterTitle = after.chapterTitle
            guard retitled == after, changed == nil else { return nil }
            changed = before.id
        }
        return changed
    }

    private func chapterSnapshot(files: [AudioFile]? = nil) -> ChapterEditSnapshot {
        ChapterEditSnapshot(files: files ?? audioFiles, metadata: bookMetadata,
            coverData: embeddedCoverData ?? coverImage?.tiffRepresentation,
            coverPath: coverPath, coverSuppressed: isCoverSuppressed)
    }

    private func restoreChapterSnapshot(_ snapshot: ChapterEditSnapshot) {
        restoringChapters = true
        // Gegenstand von Undo/Redo ist nur die Kapitelliste. Buchmetadaten und
        // Cover kommen ausschließlich dann aus dem Snapshot zurück, wenn die
        // Liste gerade leer war: `clearMetadata` hat sie beim Entfernen des
        // letzten Kapitels gelöscht (und die Cover-Suche beendet). In jedem
        // anderen Fall bleiben zwischenzeitlich eingetippte Metadaten und ein
        // gewähltes Cover erhalten, statt still zurückgesetzt zu werden.
        let wasCleared = audioFiles.isEmpty
        audioFiles = snapshot.files
        if wasCleared {
            bookMetadata = snapshot.metadata
            if snapshot.coverSuppressed { removeCover() }
            else {
                embeddedCoverData = snapshot.coverData
                coverImage = snapshot.coverData.flatMap(CoverArtwork.preview(from:))
                coverPath = snapshot.coverPath
            }
            isCoverSuppressed = snapshot.coverSuppressed
        }
        restoringChapters = false
        updateHistoryAvailability()
        if wasCleared, embeddedCoverData == nil { startArtworkSearch() }
    }

    public func undoChapterEdit() {
        guard let snapshot = undoChapters.popLast() else { return }
        redoChapters.append(chapterSnapshot())
        restoreChapterSnapshot(snapshot)
    }

    public func redoChapterEdit() {
        guard let snapshot = redoChapters.popLast() else { return }
        undoChapters.append(chapterSnapshot())
        restoreChapterSnapshot(snapshot)
    }

    public func moveChapters(from offsets: IndexSet, to destination: Int) {
        guard offsets.allSatisfy({ audioFiles.indices.contains($0) }), (0...audioFiles.count).contains(destination) else { return }
        var files = audioFiles
        let moved = offsets.sorted().map { files[$0] }
        for index in offsets.sorted(by: >) { files.remove(at: index) }
        let insertion = min(files.count, max(0, destination - offsets.filter { $0 < destination }.count))
        files.insert(contentsOf: moved, at: insertion); audioFiles = files
    }

    public func renameChapters(ids: Set<UUID>, prefix: String, startingAt: Int = 1) {
        var files = audioFiles; var number = startingAt
        for index in files.indices where ids.contains(files[index].id) {
            files[index].chapterTitle = "\(prefix) \(number)"; number += 1
        }
        audioFiles = files
    }

    public func splitChapter(id: UUID, at absoluteTime: Double) {
        guard let index = audioFiles.firstIndex(where: { $0.id == id }) else { return }
        let original = audioFiles[index]
        let offset = absoluteTime - original.startTime
        guard offset.isFinite, offset > 0.01, original.duration - offset > 0.01 else { return }
        let found = FoundFile(source: original.sourceURL, resolved: original.url)
        let first = AudioFile(foundFile: found, startTime: original.startTime, duration: offset, chapterTitle: original.chapterTitle)
        let second = AudioFile(foundFile: found, startTime: absoluteTime, duration: original.duration - offset, chapterTitle: original.chapterTitle + " (2)")
        var files = audioFiles; files.replaceSubrange(index...index, with: [first, second]); audioFiles = files
    }

    public func canMergeChapterWithNext(id: UUID) -> Bool {
        guard let index = audioFiles.firstIndex(where: { $0.id == id }),
              index + 1 < audioFiles.count else { return false }
        let first = audioFiles[index], second = audioFiles[index + 1]
        return first.url == second.url
            && first.sourceURL == second.sourceURL
            && abs(first.startTime + first.duration - second.startTime) < 0.001
    }

    public func mergeChapterWithNext(id: UUID) {
        guard canMergeChapterWithNext(id: id),
              let index = audioFiles.firstIndex(where: { $0.id == id }) else { return }
        let first = audioFiles[index], second = audioFiles[index + 1]
        let merged = AudioFile(foundFile: FoundFile(source: first.sourceURL, resolved: first.url), startTime: first.startTime, duration: first.duration + second.duration, chapterTitle: first.chapterTitle)
        var files = audioFiles; files.replaceSubrange(index...(index + 1), with: [merged]); audioFiles = files
    }
}
