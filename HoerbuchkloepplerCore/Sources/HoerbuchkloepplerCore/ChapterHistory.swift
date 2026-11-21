import AppKit
import Foundation

struct ChapterHistory {
    static let maximumUndoSteps = 100

    struct BookState {
        let metadata: BookMetadata
        let coverImage: NSImage?
        let coverData: Data?
        let coverPath: String?
        let coverSuppressed: Bool
    }

    struct Snapshot {
        let files: [AudioFile]
        let bookState: BookState?
    }

    private var undo: [Snapshot] = []
    private var redo: [Snapshot] = []

    var canUndo: Bool { !undo.isEmpty }
    var canRedo: Bool { !redo.isEmpty }
    var undoRestoresEmptyBook: Bool { undo.last?.files.isEmpty == true }
    var redoRestoresEmptyBook: Bool { redo.last?.files.isEmpty == true }

    mutating func record(_ previous: Snapshot, replacingWith files: [AudioFile]) {
        // Aufeinanderfolgende Titeleingaben im selben Kapitel ergeben einen Undo-Schritt.
        let coalesces = undo.last.map { older in
            guard let edited = Self.singleTitleEdit(from: previous.files, to: files) else { return false }
            return Self.singleTitleEdit(from: older.files, to: previous.files) == edited
        } ?? false
        if !coalesces {
            undo.append(previous)
            if undo.count > Self.maximumUndoSteps { undo.removeFirst() }
        }
        redo.removeAll()
    }

    mutating func undoEdit(current: Snapshot) -> Snapshot? {
        guard let snapshot = undo.popLast() else { return nil }
        redo.append(current)
        return snapshot
    }

    mutating func redoEdit(current: Snapshot) -> Snapshot? {
        guard let snapshot = redo.popLast() else { return nil }
        undo.append(current)
        return snapshot
    }

    func collectChapterIDs(into ids: inout Set<UUID>) {
        for snapshot in undo + redo {
            for file in snapshot.files { ids.insert(file.id) }
        }
    }

    /// Liefert die Kapitel-ID, wenn sich beide Listen ausschließlich im Titel
    /// genau eines Kapitels unterscheiden; sonst `nil`.
    private static func singleTitleEdit(from old: [AudioFile], to new: [AudioFile]) -> UUID? {
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

}

@MainActor
extension ConversionSession {
    func editChapters(_ files: [AudioFile]) {
        guard files != audioFiles else { return }
        chapterHistory.record(chapterSnapshot(clearingBook: files.isEmpty), replacingWith: files)
        applyChapterList(files)
        updateHistoryAvailability()
    }

    func updateHistoryAvailability() {
        canUndoChapters = chapterHistory.canUndo
        canRedoChapters = chapterHistory.canRedo
    }

    private func chapterSnapshot(clearingBook: Bool) -> ChapterHistory.Snapshot {
        // Nur eine leere Liste verliert Metadaten und Cover. Für reguläre
        // Bearbeitungen genügt die Kapitelliste.
        let bookState = clearingBook ? ChapterHistory.BookState(
            metadata: bookMetadata, coverImage: coverImage, coverData: embeddedCoverData,
            coverPath: coverPath, coverSuppressed: isCoverSuppressed
        ) : nil
        return ChapterHistory.Snapshot(files: audioFiles, bookState: bookState)
    }

    private func restoreChapterSnapshot(_ snapshot: ChapterHistory.Snapshot) {
        let wasCleared = audioFiles.isEmpty
        applyChapterList(snapshot.files)
        if wasCleared, let previous = snapshot.bookState {
            bookMetadata = previous.metadata
            if previous.coverSuppressed {
                removeCover()
            } else {
                embeddedCoverData = previous.coverData
                coverImage = previous.coverImage ?? previous.coverData.flatMap(CoverArtwork.preview(from:))
                coverPath = previous.coverPath
                isCoverSuppressed = false
                notifyCoverSelectionChange()
            }
        }
        updateHistoryAvailability()
        if wasCleared, !snapshot.files.isEmpty, embeddedCoverData == nil {
            startArtworkSearch()
        }
    }

    public func undoChapterEdit() {
        guard !isImporting, !isConverting else { return }
        let current = chapterSnapshot(clearingBook: chapterHistory.undoRestoresEmptyBook)
        guard let snapshot = chapterHistory.undoEdit(current: current) else { return }
        restoreChapterSnapshot(snapshot)
    }

    public func redoChapterEdit() {
        guard !isImporting, !isConverting else { return }
        let current = chapterSnapshot(clearingBook: chapterHistory.redoRestoresEmptyBook)
        guard let snapshot = chapterHistory.redoEdit(current: current) else { return }
        restoreChapterSnapshot(snapshot)
    }

    public func renameChapter(id: UUID, title: String) {
        guard let index = audioFiles.firstIndex(where: { $0.id == id }) else { return }
        var files = audioFiles
        files[index].chapterTitle = title
        editChapters(files)
    }

    public func removeChapter(id: UUID) {
        editChapters(audioFiles.filter { $0.id != id })
    }

    public func removeAllChapters() {
        editChapters([])
    }

    public func moveChapters(from offsets: IndexSet, to destination: Int) {
        guard offsets.allSatisfy({ audioFiles.indices.contains($0) }), (0...audioFiles.count).contains(destination) else { return }
        var files = audioFiles
        let moved = offsets.sorted().map { files[$0] }
        for index in offsets.sorted(by: >) { files.remove(at: index) }
        let insertion = min(files.count, max(0, destination - offsets.filter { $0 < destination }.count))
        files.insert(contentsOf: moved, at: insertion)
        editChapters(files)
    }

    public func renameChapters(ids: Set<UUID>, prefix: String, startingAt: Int = 1) {
        var files = audioFiles
        let selected = files.indices.filter { ids.contains(files[$0].id) }
        for (offset, index) in selected.enumerated() {
            let number = startingAt.addingReportingOverflow(offset)
            guard !number.overflow else { return }
            files[index].chapterTitle = "\(prefix) \(number.partialValue)"
        }
        editChapters(files)
    }

    public func splitChapter(id: UUID, at absoluteTime: Double) {
        guard let index = audioFiles.firstIndex(where: { $0.id == id }) else { return }
        let original = audioFiles[index]
        let offset = absoluteTime - original.startTime
        guard offset.isFinite, offset > 0.01, original.duration - offset > 0.01 else { return }
        let found = FoundFile(source: original.sourceURL, resolved: original.url)
        let first = AudioFile(foundFile: found, startTime: original.startTime, duration: offset, chapterTitle: original.chapterTitle)
        let second = AudioFile(foundFile: found, startTime: absoluteTime, duration: original.duration - offset, chapterTitle: original.chapterTitle + " (2)")
        inheritProjectSource(from: original.id, to: first.id)
        inheritProjectSource(from: original.id, to: second.id)
        var files = audioFiles; files.replaceSubrange(index...index, with: [first, second])
        editChapters(files)
    }

    public func canMergeChapterWithNext(id: UUID) -> Bool {
        mergeCandidate(id: id) != nil
    }

    private func mergeCandidate(id: UUID) -> (index: Int, origins: [UUID])? {
        guard let index = audioFiles.firstIndex(where: { $0.id == id }),
              index + 1 < audioFiles.count else { return nil }
        let first = audioFiles[index], second = audioFiles[index + 1]
        guard first.url == second.url, first.sourceURL == second.sourceURL,
              abs(first.startTime + first.duration - second.startTime) < 0.001,
              let origins = projectSourceOriginsForMerge(first.id, second.id) else { return nil }
        return (index, origins)
    }

    public func mergeChapterWithNext(id: UUID) {
        guard let (index, origins) = mergeCandidate(id: id) else { return }
        let first = audioFiles[index], second = audioFiles[index + 1]
        let merged = AudioFile(foundFile: FoundFile(source: first.sourceURL, resolved: first.url), startTime: first.startTime, duration: first.duration + second.duration, chapterTitle: first.chapterTitle)
        projectSourceOrigins[merged.id] = origins
        var files = audioFiles; files.replaceSubrange(index...(index + 1), with: [merged])
        editChapters(files)
    }
}
