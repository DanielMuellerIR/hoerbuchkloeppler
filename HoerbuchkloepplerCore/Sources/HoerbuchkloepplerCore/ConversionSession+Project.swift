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
                let prior = loadedProjectURL.flatMap { loadedURL in
                    projectSources.first { $0.location.resolve(from: loadedURL) == file.sourceURL }
                }
                sources.append(ProjectSource(id: id,
                    location: ProjectLocation(url: file.sourceURL, projectURL: url),
                    readLocation: ProjectLocation(url: file.url, projectURL: url),
                    sha256: try prior?.sha256 ?? ProjectSource.fingerprint(file.url)))
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
        let project = try AudiobookProject.read(from: url)
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
        else { embeddedCoverData = project.coverData; coverImage = project.coverData.flatMap(NSImage.init(data:)) }
        projectSources = project.sources; loadedProjectURL = url
        undoChapters = []; redoChapters = []; updateHistoryAvailability()
        refreshProjectSourceIssues()
    }

    public func refreshProjectSourceIssues() {
        guard let url = loadedProjectURL else { projectSourceIssues = []; return }
        let activeURLs = Set(audioFiles.map(\.sourceURL))
        projectSourceIssues = projectSources.compactMap { source in
            let visible = source.location.resolve(from: url)
            guard activeURLs.contains(visible) else { return nil }
            let readURL = source.readLocation.resolve(from: url)
            let reason: String
            do {
                guard visible.resolvingSymlinksInPath() == readURL.resolvingSymlinksInPath() else {
                    return ProjectSourceIssue(id: source.id, path: visible.path, reason: "Verknüpfung wurde verändert")
                }
                if try ProjectSource.fingerprint(readURL) == source.sha256 { return nil }
                reason = "Quelle wurde verändert"
            } catch { reason = "Quelle fehlt oder ist nicht lesbar" }
            return ProjectSourceIssue(id: source.id, path: visible.path, reason: reason)
        }
    }

    func recordChapterEdit(previous: [AudioFile]) {
        guard !restoringChapters, previous != audioFiles else { return }
        undoChapters.append(chapterSnapshot(files: previous))
        if undoChapters.count > 100 { undoChapters.removeFirst() }
        redoChapters.removeAll()
        updateHistoryAvailability()
    }

    func updateHistoryAvailability() {
        canUndoChapters = !undoChapters.isEmpty; canRedoChapters = !redoChapters.isEmpty
    }

    private func chapterSnapshot(files: [AudioFile]? = nil) -> ChapterEditSnapshot {
        ChapterEditSnapshot(files: files ?? audioFiles, metadata: bookMetadata,
            coverData: embeddedCoverData ?? coverImage?.tiffRepresentation,
            coverPath: coverPath, coverSuppressed: isCoverSuppressed)
    }

    private func restoreChapterSnapshot(_ snapshot: ChapterEditSnapshot) {
        restoringChapters = true
        audioFiles = snapshot.files
        bookMetadata = snapshot.metadata
        if snapshot.coverSuppressed { removeCover() }
        else {
            // `clearMetadata` beendet bei leerer Liste die Cover-Suche. Durch
            // den Snapshot stellt Undo exakt den zuvor sichtbaren Stand her.
            embeddedCoverData = snapshot.coverData
            coverImage = snapshot.coverData.flatMap(NSImage.init(data:))
            coverPath = snapshot.coverPath
        }
        isCoverSuppressed = snapshot.coverSuppressed
        restoringChapters = false
        updateHistoryAvailability()
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

    public func mergeChapterWithNext(id: UUID) {
        guard let index = audioFiles.firstIndex(where: { $0.id == id }), index + 1 < audioFiles.count else { return }
        let first = audioFiles[index], second = audioFiles[index + 1]
        guard first.url == second.url, first.sourceURL == second.sourceURL,
              abs(first.startTime + first.duration - second.startTime) < 0.001 else { return }
        let merged = AudioFile(foundFile: FoundFile(source: first.sourceURL, resolved: first.url), startTime: first.startTime, duration: first.duration + second.duration, chapterTitle: first.chapterTitle)
        var files = audioFiles; files.replaceSubrange(index...(index + 1), with: [merged]); audioFiles = files
    }
}
