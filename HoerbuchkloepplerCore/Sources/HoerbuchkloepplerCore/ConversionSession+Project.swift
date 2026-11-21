import Foundation
import AppKit

struct ChapterEditSnapshot {
    var files: [AudioFile]
    var metadata: BookMetadata
    var coverData: Data?
    var coverPath: String?
    var coverSuppressed: Bool
}

private let projectWriteQueue = DispatchQueue(label: "de.hoerbuchkloeppler.projects.write")

private func performProjectIO<Result: Sendable>(_ work: @escaping @Sendable () throws -> Result) async throws -> Result {
    let task = Task.detached(priority: Task.currentPriority) {
        try Task.checkCancellation()
        let result = try work()
        try Task.checkCancellation()
        return result
    }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
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
        let chapters = try Self.projectChapters(files: audioFiles, priorSources: projectSources,
            priorURL: loadedProjectURL, destination: url, fingerprints: projectFingerprints)
        return project(with: chapters)
    }

    private func project(with chapters: (sources: [ProjectSource], sections: [ProjectSection])) -> AudiobookProject {
        AudiobookProject(sources: chapters.sources, sections: chapters.sections, metadata: bookMetadata,
            settings: settings, coverData: embeddedCoverData ?? coverImage?.tiffRepresentation,
            coverSuppressed: isCoverSuppressed)
    }

    private nonisolated static func projectChapters(
        files: [AudioFile], priorSources: [ProjectSource], priorURL: URL?, destination: URL,
        fingerprints: ProjectFingerprintStore
    ) throws -> (sources: [ProjectSource], sections: [ProjectSection]) {
        var priorHashes: [URL: String] = [:]
        if let priorURL {
            priorHashes = Dictionary(priorSources.map { ($0.location.resolve(from: priorURL), $0.sha256) },
                uniquingKeysWith: { first, _ in first })
        }
        var sources: [ProjectSource] = []
        var sections: [ProjectSection] = []
        var ids: [URL: UUID] = [:]
        for file in files {
            try Task.checkCancellation()
            let id: UUID
            if let existing = ids[file.sourceURL] { id = existing }
            else {
                id = UUID(); ids[file.sourceURL] = id
                let prior = priorHashes[file.sourceURL.standardizedFileURL]
                sources.append(ProjectSource(id: id,
                    location: ProjectLocation(url: file.sourceURL, projectURL: destination),
                    readLocation: ProjectLocation(url: file.url, projectURL: destination),
                    sha256: try prior ?? fingerprints.fingerprint(file.url)))
            }
            sections.append(ProjectSection(id: file.id, sourceID: id, start: file.startTime, duration: file.duration, title: file.chapterTitle))
        }
        return (sources, sections)
    }

    public func saveProject(to url: URL) throws {
        projectOperation = UUID()
        refreshProjectSourceIssues()
        let project = try makeProject(at: url)
        try projectWriteQueue.sync { try project.write(to: url) }
        projectSources = project.sources; loadedProjectURL = url
        refreshProjectSourceIssues()
    }

    public func openProject(from url: URL) throws {
        guard !isConverting else { throw ProjectError.invalid("Während einer Konvertierung kann kein Projekt geöffnet werden.") }
        projectOperation = UUID()
        let project = try AudiobookProject.read(from: url)
        let files = Self.audioFiles(in: project, at: url)
        let issues = try Self.sourceIssues(project.sources, at: url, files: files, fingerprints: projectFingerprints)
        try applyProject(project, from: url, files: files, issues: issues)
    }

    private nonisolated static func audioFiles(in project: AudiobookProject, at url: URL) -> [AudioFile] {
        let sources = Dictionary(uniqueKeysWithValues: project.sources.map { ($0.id, $0) })
        return project.sections.compactMap { section -> AudioFile? in
            guard let source = sources[section.sourceID] else { return nil }
            var file = AudioFile(foundFile: FoundFile(source: source.location.resolve(from: url), resolved: source.readLocation.resolve(from: url)), startTime: section.start, duration: section.duration, chapterTitle: section.title)
            file.id = section.id
            return file
        }
    }

    private func applyProject(_ project: AudiobookProject, from url: URL, files: [AudioFile], issues: [ProjectSourceIssue]) throws {
        guard !isConverting else { throw ProjectError.invalid("Während einer Konvertierung kann kein Projekt geöffnet werden.") }
        // Erst vollständig dekodieren, danach bestehenden Zustand ersetzen.
        resetSession()
        audioFiles = files
        bookMetadata = project.metadata
        settings = project.settings.normalized()
        if project.coverSuppressed { removeCover() }
        else { embeddedCoverData = project.coverData; coverImage = project.coverData.flatMap(CoverArtwork.preview(from:)) }
        projectSources = project.sources; loadedProjectURL = url
        undoChapters = []; redoChapters = []; updateHistoryAvailability()
        projectSourceIssues = issues
    }

    public func openProjectAsync(from url: URL) async throws {
        try Task.checkCancellation()
        guard !isConverting else { throw ProjectError.invalid("Während einer Konvertierung kann kein Projekt geöffnet werden.") }
        let operation = UUID(); projectOperation = operation
        let fingerprints = projectFingerprints
        let (project, files, issues) = try await performProjectIO {
            let project = try AudiobookProject.read(from: url)
            let files = Self.audioFiles(in: project, at: url)
            let issues = try Self.sourceIssues(project.sources, at: url, files: files, fingerprints: fingerprints)
            return (project, files, issues)
        }
        try Task.checkCancellation()
        // Ein zwischenzeitlicher Import oder ein neueres Öffnen hat diesen
        // Vorgang ersetzt. Das still zu schlucken hieße: Das Projekt öffnet
        // sich einfach nicht, ohne dass jemand erfährt warum.
        guard projectOperation == operation else {
            throw ProjectError.invalid("Das Öffnen wurde durch eine andere Aktion unterbrochen; bitte erneut öffnen.")
        }
        try applyProject(project, from: url, files: files, issues: issues)
    }

    public func saveProjectAsync(to url: URL) async throws {
        try await saveProjectAsync(to: url) { project, destination in
            // Sonst könnte ein langsamer älterer Vorgang eine neuere Datei überschreiben.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                projectWriteQueue.async {
                    continuation.resume(with: Result { try project.write(to: destination) })
                }
            }
        }
    }

    func saveProjectAsync(
        to url: URL,
        writeProject: @Sendable (AudiobookProject, URL) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let operation = UUID(); projectOperation = operation
        let files = audioFiles
        let priorSources = projectSources
        let priorURL = loadedProjectURL
        let fingerprints = projectFingerprints
        let (chapters, issues) = try await performProjectIO {
            let chapters = try Self.projectChapters(files: files, priorSources: priorSources, priorURL: priorURL,
                destination: url, fingerprints: fingerprints)
            let issues = try Self.sourceIssues(chapters.sources, at: url, files: files, fingerprints: fingerprints)
            return (chapters, issues)
        }
        try Task.checkCancellation()
        // Sonst hielte der Nutzer das Projekt für gespeichert, obwohl nichts
        // geschrieben wurde — der Konfliktfall eine Zeile weiter meldet sich
        // aus demselben Grund.
        guard projectOperation == operation else {
            throw ProjectError.invalid("Das Speichern wurde durch eine andere Aktion unterbrochen; bitte erneut speichern.")
        }
        guard files == audioFiles else { throw ProjectError.invalid("Kapitel wurden während des Speicherns verändert; bitte erneut speichern.") }
        let savedCoverImage = coverImage
        let savedCoverData = embeddedCoverData
        let project = project(with: chapters)
        try await writeProject(project, url)
        // Ein Import oder Öffnen darf den bereits geschriebenen Stand nicht an
        // seinen eigenen, inzwischen aktiven Zustand binden.
        guard projectOperation == operation else {
            throw ProjectError.invalid("Die Projektdatei wurde geschrieben. Eine andere Aktion hat inzwischen das aktive Projekt verändert.")
        }
        projectSources = project.sources; loadedProjectURL = url
        guard files == audioFiles, project.metadata == bookMetadata, project.settings == settings,
              savedCoverImage === coverImage, savedCoverData == embeddedCoverData,
              project.coverSuppressed == isCoverSuppressed else {
            try? refreshProjectSourceIssues(policy: .cachedOnly)
            throw ProjectError.invalid("Die Projektdatei enthält den Stand vor den letzten Änderungen. Bitte erneut speichern.")
        }
        projectSourceIssues = issues
    }

    public func refreshProjectSourceIssues() {
        try? refreshProjectSourceIssues(policy: .synchronous)
    }

    public func verifyProjectSources() async throws {
        guard let url = loadedProjectURL else { projectSourceIssues = []; return }
        let operation = projectOperation
        let files = audioFiles
        let sources = projectSources
        let fingerprints = projectFingerprints
        let issues = try await performProjectIO {
            try Self.sourceIssues(sources, at: url, files: files, fingerprints: fingerprints)
        }
        try Task.checkCancellation()
        guard projectOperation == operation, files == audioFiles, url == loadedProjectURL else {
            throw ProjectError.invalid("Das Projekt wurde während der Prüfung verändert; bitte erneut starten.")
        }
        projectSourceIssues = issues
    }

    func refreshProjectSourceIssues(
        policy: ProjectFingerprintStore.ReadPolicy, plan: ConversionPlan? = nil
    ) throws {
        projectSourceIssues = try Self.sourceIssues(projectSources, at: loadedProjectURL,
            files: plan?.groups.flatMap { $0 } ?? audioFiles,
            fingerprints: projectFingerprints, policy: policy, plannedInputs: plan?.inputSnapshots)
    }

    private nonisolated static func sourceIssues(
        _ sources: [ProjectSource], at url: URL?, files: [AudioFile],
        fingerprints: ProjectFingerprintStore, policy: ProjectFingerprintStore.ReadPolicy = .verifyCurrent,
        plannedInputs: [String: OutputDestinationSnapshot]? = nil
    ) throws -> [ProjectSourceIssue] {
        try Task.checkCancellation()
        guard let url else { return [] }
        var activeReadURLs: [URL: Set<URL>] = [:]
        for file in files {
            activeReadURLs[file.sourceURL.standardizedFileURL, default: []].insert(file.url)
        }
        let issues = try sources.compactMap { source -> ProjectSourceIssue? in
            try Task.checkCancellation()
            let visible = source.location.resolve(from: url)
            guard let readURLs = activeReadURLs[visible] else { return nil }
            let readURL = source.readLocation.resolve(from: url)
            let reason: String
            guard visible.resolvingSymlinksInPath() == readURL.resolvingSymlinksInPath() else {
                return ProjectSourceIssue(id: source.id, path: visible.path, reason: "Verknüpfung wurde verändert")
            }
            switch fingerprints.verify(readURL, expectedSHA256: source.sha256, policy: policy) {
            case .unchanged(let identity):
                // Der Export muss denselben Snapshot lesen, der den Projekt-Hash
                // geliefert hat. Pfad und Session allein binden den Plan nicht daran.
                let matchesPlan = plannedInputs.map { inputs in
                    readURLs.allSatisfy { url in
                        guard case .existing(let planned) = inputs[FFmpegWrapper.canonicalPath(url)] else { return false }
                        return planned.matchesContentSnapshot(identity)
                    }
                } ?? true
                guard !matchesPlan else { return nil }
                reason = "Quelle wurde verändert"
            case .changed: reason = "Quelle wurde verändert"
            case .unreadable: reason = "Quelle fehlt oder ist nicht lesbar"
            }
            return ProjectSourceIssue(id: source.id, path: visible.path, reason: reason)
        }
        try Task.checkCancellation()
        return issues
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
                isCoverSuppressed = false
                notifyCoverSelectionChange()
            }
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
