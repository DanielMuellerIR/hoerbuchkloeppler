import Foundation
import AppKit

private let projectWriteQueue = DispatchQueue(label: "de.hoerbuchkloeppler.projects.write")

struct ProjectSourceBinding: Equatable, Sendable {
    struct Content: Hashable, Sendable {
        let visibleURL: URL
        let readURL: URL
        let sha256: String
    }

    let id: UUID
    let content: Content

    init(source: ProjectSource, projectURL: URL) {
        id = source.id
        content = Content(visibleURL: source.location.resolve(from: projectURL),
                          readURL: source.readLocation.resolve(from: projectURL), sha256: source.sha256)
    }
}

func performFileIO<Result: Sendable>(_ work: @escaping @Sendable () throws -> Result) async throws -> Result {
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
        let bindings = try projectBindings(for: audioFiles)
        let chapters = try Self.projectChapters(files: audioFiles, priorBindings: bindings,
            destination: url, fingerprints: projectFingerprints)
        return project(with: chapters)
    }

    private func project(with chapters: (sources: [ProjectSource], sections: [ProjectSection])) -> AudiobookProject {
        AudiobookProject(sources: chapters.sources, sections: chapters.sections, metadata: bookMetadata,
            settings: settings, coverData: embeddedCoverData ?? coverImage?.tiffRepresentation,
            coverSuppressed: isCoverSuppressed)
    }

    private nonisolated static func projectChapters(
        files: [AudioFile], priorBindings: [UUID: ProjectSourceBinding], destination: URL,
        fingerprints: ProjectFingerprintStore
    ) throws -> (sources: [ProjectSource], sections: [ProjectSection]) {
        var sources: [ProjectSource] = []
        var sections: [ProjectSection] = []
        var ids: [ProjectSourceBinding.Content: UUID] = [:]
        var newHashes: [URL: String] = [:]
        for file in files {
            try Task.checkCancellation()
            let prior = priorBindings[file.id]
            let content: ProjectSourceBinding.Content
            if let prior {
                content = prior.content
            } else {
                let readURL = file.url.standardizedFileURL
                let sha256 = try newHashes[readURL] ?? fingerprints.fingerprint(readURL)
                newHashes[readURL] = sha256
                content = ProjectSourceBinding.Content(visibleURL: file.sourceURL.standardizedFileURL,
                    readURL: readURL, sha256: sha256)
            }
            let id: UUID
            if let existing = ids[content] {
                id = existing
            } else {
                id = prior?.id ?? UUID()
                ids[content] = id
                sources.append(ProjectSource(id: id,
                    location: ProjectLocation(url: content.visibleURL, projectURL: destination),
                    readLocation: ProjectLocation(url: content.readURL, projectURL: destination),
                    sha256: content.sha256))
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
        rememberProjectBindings(Self.projectBindings(in: project, at: url), at: url)
        refreshProjectSourceIssues()
    }

    public func openProject(from url: URL) throws {
        guard !isConverting else { throw ProjectError.invalid("Während einer Konvertierung kann kein Projekt geöffnet werden.") }
        projectOperation = UUID()
        let project = try AudiobookProject.read(from: url)
        let bindings = Self.projectBindings(in: project, at: url)
        let files = Self.audioFiles(in: project, bindings: bindings)
        let issues = try Self.sourceIssues(bindings, files: files, fingerprints: projectFingerprints)
        try applyProject(project, from: url, files: files, bindings: bindings, issues: issues,
            artwork: Self.projectArtwork(project))
    }

    private nonisolated static func audioFiles(
        in project: AudiobookProject, bindings: [UUID: ProjectSourceBinding]
    ) -> [AudioFile] {
        return project.sections.compactMap { section -> AudioFile? in
            guard let source = bindings[section.id]?.content else { return nil }
            var file = AudioFile(foundFile: FoundFile(source: source.visibleURL, resolved: source.readURL),
                startTime: section.start, duration: section.duration, chapterTitle: section.title)
            file.id = section.id
            return file
        }
    }

    private nonisolated static func projectArtwork(_ project: AudiobookProject) -> PreparedEmbeddedArtwork? {
        project.coverSuppressed ? nil : project.coverData.flatMap(PreparedEmbeddedArtwork.init)
    }

    private func applyProject(
        _ project: AudiobookProject, from url: URL, files: [AudioFile],
        bindings: [UUID: ProjectSourceBinding], issues: [ProjectSourceIssue],
        artwork: PreparedEmbeddedArtwork?
    ) throws {
        guard !isConverting else { throw ProjectError.invalid("Während einer Konvertierung kann kein Projekt geöffnet werden.") }
        // Erst vollständig dekodieren, danach bestehenden Zustand ersetzen.
        resetSession()
        audioFiles = files
        bookMetadata = project.metadata
        settings = project.settings.normalized()
        if project.coverSuppressed { removeCover() }
        else { embeddedCoverData = project.coverData; coverImage = artwork?.image }
        rememberProjectBindings(bindings, at: url)
        recordProjectSourceIssues(issues, for: bindings)
    }

    public func openProjectAsync(from url: URL) async throws {
        try Task.checkCancellation()
        guard !isConverting else { throw ProjectError.invalid("Während einer Konvertierung kann kein Projekt geöffnet werden.") }
        let operation = UUID(); projectOperation = operation
        let previousFiles = audioFiles
        let previousMetadata = bookMetadata
        let previousSettings = settings
        let previousCoverImage = coverImage
        let previousCoverPath = coverPath
        let previousCoverData = embeddedCoverData
        let previousCoverSuppressed = isCoverSuppressed
        let fingerprints = projectFingerprints
        let (project, files, bindings, issues, artwork) = try await performFileIO {
            let project = try AudiobookProject.read(from: url)
            let bindings = Self.projectBindings(in: project, at: url)
            let files = Self.audioFiles(in: project, bindings: bindings)
            let issues = try Self.sourceIssues(bindings, files: files, fingerprints: fingerprints)
            return (project, files, bindings, issues, Self.projectArtwork(project))
        }
        try Task.checkCancellation()
        // Ein zwischenzeitlicher Import oder ein neueres Öffnen hat diesen
        // Vorgang ersetzt. Das still zu schlucken hieße: Das Projekt öffnet
        // sich einfach nicht, ohne dass jemand erfährt warum.
        guard projectOperation == operation else {
            throw ProjectError.invalid("Das Öffnen wurde durch eine andere Aktion unterbrochen; bitte erneut öffnen.")
        }
        guard previousFiles == audioFiles, previousMetadata == bookMetadata, previousSettings == settings,
              previousCoverImage === coverImage, previousCoverPath == coverPath, previousCoverData == embeddedCoverData,
              previousCoverSuppressed == isCoverSuppressed else {
            throw ProjectError.invalid("Das aktive Projekt wurde beim Öffnen bearbeitet. Bitte erneut öffnen.")
        }
        try applyProject(project, from: url, files: files, bindings: bindings, issues: issues, artwork: artwork)
    }

    public func saveProjectAsync(to url: URL) async throws {
        try await saveProjectAsync(to: url, didEnqueue: {})
    }

    func saveProjectAsync(to url: URL, didEnqueue: () -> Void) async throws {
        try Task.checkCancellation()
        let operation = UUID(); projectOperation = operation
        let files = audioFiles
        let priorBindings = try projectBindings(for: files)
        let fingerprints = projectFingerprints
        let (chapters, bindings, issues) = try await performFileIO {
            let chapters = try Self.projectChapters(files: files, priorBindings: priorBindings,
                destination: url, fingerprints: fingerprints)
            let bindings = Self.projectBindings(sources: chapters.sources, sections: chapters.sections, at: url)
            let issues = try Self.sourceIssues(bindings, files: files, fingerprints: fingerprints)
            return (chapters, bindings, issues)
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
        // Kapitel können während des Schreibens zusammengeführt werden. Dabei
        // muss auch die Bindung des Schreibstands vererbbar sein.
        let bindingsByOrigin = projectBindingsByOrigin(bindings)
        projectSourcesBeingWritten = (operation, Set(bindings.keys), bindingsByOrigin)
        defer {
            if projectSourcesBeingWritten?.operation == operation { projectSourcesBeingWritten = nil }
        }
        // Die Warteschlange erhält den Auftrag noch auf dem Main Actor.
        // So kann eine neuere Speicherung ihn nicht beim Einreihen überholen.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            projectWriteQueue.async {
                continuation.resume(with: Result { try project.write(to: url) })
            }
            didEnqueue()
        }
        // Ein Import oder Öffnen darf den bereits geschriebenen Stand nicht an
        // seinen eigenen, inzwischen aktiven Zustand binden.
        guard projectOperation == operation else {
            throw ProjectError.invalid("Die Projektdatei wurde geschrieben. Eine andere Aktion hat inzwischen das aktive Projekt verändert.")
        }
        rememberProjectSourceOrigins(bindingsByOrigin)
        loadedProjectURL = url
        recordProjectSourceIssues(issues, for: bindings)
        guard files == audioFiles, project.metadata == bookMetadata, project.settings == settings,
              savedCoverImage === coverImage, savedCoverData == embeddedCoverData,
              project.coverSuppressed == isCoverSuppressed else {
            try? refreshProjectSourceIssues(policy: .cachedOnly)
            throw ProjectError.invalid("Die Projektdatei enthält den Stand vor den letzten Änderungen. Bitte erneut speichern.")
        }
    }

    public func refreshProjectSourceIssues() {
        try? refreshProjectSourceIssues(policy: .synchronous)
    }

    public func verifyProjectSources() async throws {
        try await verifyProjectSources(policy: .verifyCurrent)
    }

    func verifyProjectSources(policy: ProjectFingerprintStore.ReadPolicy, plan: ConversionPlan? = nil) async throws {
        let operation = projectOperation
        let files = audioFiles
        let bindings = try projectBindings(for: files)
        guard !bindings.isEmpty else {
            updateActiveProjectSourceIssues()
            return
        }
        let fingerprints = projectFingerprints
        let issues = try await performFileIO {
            try Self.sourceIssues(bindings, files: files, fingerprints: fingerprints,
                policy: policy, plannedInputs: plan?.inputSnapshots)
        }
        try Task.checkCancellation()
        guard projectOperation == operation, files == audioFiles,
              bindings == (try? projectBindings(for: files)) else {
            throw ProjectError.invalid("Das Projekt wurde während der Prüfung verändert; bitte erneut starten.")
        }
        recordProjectSourceIssues(issues, for: bindings)
    }

    func refreshProjectSourceIssues(
        policy: ProjectFingerprintStore.ReadPolicy, plan: ConversionPlan? = nil
    ) throws {
        let files = plan?.groups.flatMap { $0 } ?? audioFiles
        let bindings = try projectBindings(for: files)
        let issues = try Self.sourceIssues(bindings, files: files,
            fingerprints: projectFingerprints, policy: policy, plannedInputs: plan?.inputSnapshots)
        recordProjectSourceIssues(issues, for: bindings)
    }

    private nonisolated static func projectBindings(in project: AudiobookProject, at url: URL) -> [UUID: ProjectSourceBinding] {
        projectBindings(sources: project.sources, sections: project.sections, at: url)
    }

    private nonisolated static func projectBindings(
        sources: [ProjectSource], sections: [ProjectSection], at url: URL
    ) -> [UUID: ProjectSourceBinding] {
        let bySourceID = Dictionary(uniqueKeysWithValues: sources.map {
            ($0.id, ProjectSourceBinding(source: $0, projectURL: url))
        })
        var bindings: [UUID: ProjectSourceBinding] = [:]
        for section in sections {
            bindings[section.id] = bySourceID[section.sourceID]
        }
        return bindings
    }

    private func projectSourceOrigins(of chapterID: UUID) -> [UUID] {
        projectSourceOrigins[chapterID] ?? [chapterID]
    }

    private func projectSourceBinding(
        for chapterID: UUID, pending: [UUID: ProjectSourceBinding]? = nil
    ) -> (binding: ProjectSourceBinding?, conflict: Bool) {
        guard let origins = projectSourceOrigins[chapterID] else {
            return (projectSourcesByOrigin[chapterID] ?? pending?[chapterID], false)
        }
        var previous: ProjectSourceBinding?
        for origin in origins {
            guard let source = projectSourcesByOrigin[origin] ?? pending?[origin] else { continue }
            if let previous, previous.content != source.content { return (nil, true) }
            if previous == nil { previous = source }
        }
        return (previous, false)
    }

    func projectSourceOriginsForMerge(_ first: UUID, _ second: UUID) -> [UUID]? {
        let pending = projectSourcesBeingWritten?.operation == projectOperation
            ? projectSourcesBeingWritten?.byOrigin : nil
        let (firstBinding, firstConflict) = projectSourceBinding(for: first, pending: pending)
        let (secondBinding, secondConflict) = projectSourceBinding(for: second, pending: pending)
        guard !firstConflict && !secondConflict else { return nil }
        if let firstBinding, let secondBinding, firstBinding.content != secondBinding.content { return nil }
        let firstOrigins = projectSourceOrigins(of: first)
        let secondOrigins = projectSourceOrigins(of: second)
        // Bereits gebundene Abschnitte schützen den Merge. Ein unabhängig
        // neu importierter Abschnitt behält beim Undo seinen eigenen Ursprung.
        if projectSourceBinding(for: first).binding != nil { return firstOrigins }
        if projectSourceBinding(for: second).binding != nil { return secondOrigins }
        // Ein später erstmals gespeicherter Merge bindet beide Ausgangskapitel.
        let firstOriginIDs = Set(firstOrigins)
        return firstOrigins + secondOrigins.filter { !firstOriginIDs.contains($0) }
    }

    func inheritProjectSource(from chapterID: UUID, to derivedChapterID: UUID) {
        projectSourceOrigins[derivedChapterID] = projectSourceOrigins(of: chapterID)
    }

    private static let conflictingProjectSources = "Zusammengeführtes Kapitel hat unterschiedliche Quellfingerprints. Bitte die Zusammenführung rückgängig machen."

    private func projectBindings(for files: [AudioFile]) throws -> [UUID: ProjectSourceBinding] {
        guard !projectSourcesByOrigin.isEmpty else { return [:] }
        var bindings: [UUID: ProjectSourceBinding] = [:]
        for file in files {
            let (binding, conflict) = projectSourceBinding(for: file.id)
            if conflict { throw ProjectError.invalid(Self.conflictingProjectSources) }
            bindings[file.id] = binding
        }
        return bindings
    }

    private func rememberProjectBindings(_ bindings: [UUID: ProjectSourceBinding], at url: URL) {
        rememberProjectSourceOrigins(projectBindingsByOrigin(bindings))
        loadedProjectURL = url
    }

    private func rememberProjectSourceOrigins(_ bindings: [UUID: ProjectSourceBinding]) {
        projectSourcesByOrigin.merge(bindings) { previous, saved in
            previous.content == saved.content ? saved : previous
        }
    }

    private func projectBindingsByOrigin(_ bindings: [UUID: ProjectSourceBinding]) -> [UUID: ProjectSourceBinding] {
        var byOrigin: [UUID: ProjectSourceBinding] = [:]
        for (chapterID, binding) in bindings {
            for origin in projectSourceOrigins(of: chapterID) { byOrigin[origin] = binding }
        }
        return byOrigin
    }

    func compactProjectSourceHistoryIfNeeded() {
        guard !projectSourceOrigins.isEmpty || !projectSourcesByOrigin.isEmpty else { return }
        projectSourceRetentionEdits += 1
        // Unverzweigte Bearbeitungen sollen die Historie nicht pro Klick lesen.
        guard projectSourceRetentionEdits == ChapterHistory.maximumUndoSteps else { return }
        projectSourceRetentionEdits = 0
        var chapterIDs = Set(audioFiles.map(\.id))
        chapterHistory.collectChapterIDs(into: &chapterIDs)
        if let writing = projectSourcesBeingWritten, writing.operation == projectOperation {
            chapterIDs.formUnion(writing.chapterIDs)
        }
        projectSourceOrigins = projectSourceOrigins.filter { chapterIDs.contains($0.key) }
        var originIDs = chapterIDs
        for origins in projectSourceOrigins.values { originIDs.formUnion(origins) }
        projectSourcesByOrigin = projectSourcesByOrigin.filter { originIDs.contains($0.key) }
        let sourceIDs = Set(projectSourcesByOrigin.values.map(\.id))
        projectSourceIssuesByID = projectSourceIssuesByID.filter { sourceIDs.contains($0.key) }
    }

    private func recordProjectSourceIssues(_ issues: [ProjectSourceIssue], for bindings: [UUID: ProjectSourceBinding]) {
        for binding in bindings.values {
            projectSourceIssuesByID.removeValue(forKey: binding.id)
        }
        for issue in issues {
            projectSourceIssuesByID[issue.id] = issue
        }
        updateActiveProjectSourceIssues()
    }

    func updateActiveProjectSourceIssues() {
        guard !projectSourceIssuesByID.isEmpty
                || (!projectSourcesByOrigin.isEmpty && !projectSourceOrigins.isEmpty) else {
            if !projectSourceIssues.isEmpty { projectSourceIssues = [] }
            return
        }
        var activeIDs = Set<UUID>()
        let issues = audioFiles.compactMap { file -> ProjectSourceIssue? in
            let (binding, conflict) = projectSourceBinding(for: file.id)
            if conflict {
                return ProjectSourceIssue(id: file.id, path: file.sourceURL.path,
                    reason: Self.conflictingProjectSources)
            }
            guard let id = binding?.id,
                  activeIDs.insert(id).inserted else { return nil }
            return projectSourceIssuesByID[id]
        }
        if projectSourceIssues != issues { projectSourceIssues = issues }
    }

    private nonisolated static func sourceIssues(
        _ bindings: [UUID: ProjectSourceBinding], files: [AudioFile],
        fingerprints: ProjectFingerprintStore, policy: ProjectFingerprintStore.ReadPolicy = .verifyCurrent,
        plannedInputs: [String: OutputDestinationSnapshot]? = nil
    ) throws -> [ProjectSourceIssue] {
        try Task.checkCancellation()
        guard !bindings.isEmpty else { return [] }
        var checked = Set<UUID>()
        var changedPaths = Set<UUID>()
        for file in files {
            try Task.checkCancellation()
            guard let binding = bindings[file.id] else { continue }
            if file.sourceURL.standardizedFileURL != binding.content.visibleURL
                || file.url.standardizedFileURL != binding.content.readURL {
                changedPaths.insert(binding.id)
            }
        }
        let issues = try files.compactMap { file -> ProjectSourceIssue? in
            try Task.checkCancellation()
            guard let binding = bindings[file.id], checked.insert(binding.id).inserted else { return nil }
            let visible = binding.content.visibleURL
            let readURL = binding.content.readURL
            let reason: String
            guard !changedPaths.contains(binding.id),
                  visible.resolvingSymlinksInPath() == readURL.resolvingSymlinksInPath() else {
                return ProjectSourceIssue(id: binding.id, path: visible.path, reason: "Verknüpfung wurde verändert")
            }
            switch fingerprints.verify(readURL, expectedSHA256: binding.content.sha256, policy: policy) {
            case .unchanged(let identity):
                // Der Export muss denselben Snapshot lesen, der den Projekt-Hash
                // geliefert hat. Pfad und Session allein binden den Plan nicht daran.
                let matchesPlan = plannedInputs.map { inputs in
                    guard case .existing(let planned) = inputs[FileSystemEntry.canonicalPath(readURL)] else { return false }
                    return planned.matchesContentSnapshot(identity)
                } ?? true
                guard !matchesPlan else { return nil }
                reason = "Quelle wurde verändert"
            case .changed: reason = "Quelle wurde verändert"
            case .unreadable: reason = "Quelle fehlt oder ist nicht lesbar"
            }
            return ProjectSourceIssue(id: binding.id, path: visible.path, reason: reason)
        }
        try Task.checkCancellation()
        return issues
    }
}
