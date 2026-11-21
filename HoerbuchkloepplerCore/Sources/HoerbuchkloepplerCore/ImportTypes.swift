import Foundation

public struct ImportToken: Equatable, Sendable {
    let generation: UUID
    let coverRevision: UInt
    let allowsSelectionUI: Bool
}

public struct AudioImportFailure: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case unreadableDuration
        case noAudioTrack
        case chapterAnalysisTimedOut
        case analysisFailed
        case sourceChanged
        case providerLoadFailed(String?)
    }

    public enum Source: Equatable, Sendable {
        case file(URL)
        case dropItem(position: Int, total: Int)
    }

    public let source: Source
    public let reason: Reason

    public init(sourceURL: URL, reason: Reason) {
        self.source = .file(sourceURL)
        self.reason = reason
    }

    init(dropItemAt position: Int, total: Int, details: String?) {
        let safePosition = max(1, position)
        source = .dropItem(position: safePosition, total: max(safePosition, total))
        let normalizedDetails = details?
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        reason = .providerLoadFailed(normalizedDetails)
    }

    public var sourceDescription: String {
        switch source {
        case .file(let url):
            return url.lastPathComponent
        case .dropItem(let position, let total):
            return total > 1 ? "Drop-Element \(position) von \(total)" : "Drop-Element \(position)"
        }
    }

    public var message: String {
        switch reason {
        case .unreadableDuration:
            return "Keine positive Audiodauer lesbar"
        case .noAudioTrack:
            return "Kein lesbarer Audio-Stream enthalten"
        case .chapterAnalysisTimedOut:
            return "Kapitelanalyse hat das Zeitlimit überschritten"
        case .analysisFailed:
            return "Audioanalyse fehlgeschlagen"
        case .sourceChanged:
            return "Quelldatei wurde während der Analyse verändert"
        case .providerLoadFailed(let details):
            if let details, !details.isEmpty {
                return "Datei-URL konnte nicht geladen werden (\(details))"
            }
            return "Datei-URL konnte nicht geladen werden"
        }
    }

    var logMessage: String {
        "❌ \(sourceDescription): \(message)."
    }
}

/// Typisiertes Ergebnis genau einer Eingangsdatei. Ein absichtlicher Skip
/// (beispielsweise ein gedropptes Bild) bleibt von Analysefehler und Abbruch
/// unterscheidbar, damit ein Mehrdateien-Import atomar entschieden werden kann.
enum AudioLoadResult: Sendable {
    case success(files: [AudioFile], warnings: [String])
    case skipped
    case failure(AudioImportFailure)
    case cancelled

    var files: [AudioFile] {
        guard case .success(let files, _) = self else { return [] }
        return files
    }

    var warnings: [String] {
        guard case .success(_, let warnings) = self else { return [] }
        return warnings
    }

    var failures: [AudioImportFailure] {
        guard case .failure(let failure) = self else { return [] }
        return [failure]
    }

    var wasCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

/// Ergebnis eines Ordner-Scans. Enthält keinen `@Published`-State und kann
/// deshalb sicher von der Audioanalyse zum Main Actor übertragen werden.
struct ScannedFolder: Sendable {
    var folderURL: URL
    var audioFiles: [AudioFile]
    var imageURLs: [URL]
    var embeddedArtwork: Data?
    var warnings: [String]
    var failures: [AudioImportFailure]
    var wasCancelled: Bool

    init(
        folderURL: URL,
        audioFiles: [AudioFile],
        imageURLs: [URL],
        embeddedArtwork: Data?,
        warnings: [String] = [],
        failures: [AudioImportFailure] = [],
        wasCancelled: Bool = false
    ) {
        self.folderURL = folderURL
        self.audioFiles = audioFiles
        self.imageURLs = imageURLs
        self.embeddedArtwork = embeddedArtwork
        self.warnings = warnings
        self.failures = failures
        self.wasCancelled = wasCancelled
    }
}

public enum FileProviderItem: Sendable {
    case url(URL)
    case failure(String?)
}

public enum FileProviderImportResult: Sendable {
    case ready([FileProviderItem])
    case timedOut
    case cancelled
}

struct PendingImportBatch {
    var remainingItems: Int
    let canRepresentFolder: Bool
    let shouldResumeArtworkSearch: Bool
    var audioFiles: [AudioFile] = []
    var imageURLs: [URL] = []
    var embeddedArtwork: Data?
    var warnings: [String] = []
    var failures: [AudioImportFailure] = []
    var wasCancelled = false
    var requiresArtworkSearch = false
    var sourceFolder: URL?

    init(expectedItemCount: Int, shouldResumeArtworkSearch: Bool) {
        remainingItems = max(0, expectedItemCount)
        canRepresentFolder = expectedItemCount == 1
        self.shouldResumeArtworkSearch = shouldResumeArtworkSearch
    }

    mutating func stage(_ result: AudioLoadResult) {
        switch result {
        case .success(let files, let warnings):
            audioFiles.append(contentsOf: files)
            self.warnings.append(contentsOf: warnings)
            requiresArtworkSearch = requiresArtworkSearch || !files.isEmpty
        case .failure(let failure):
            failures.append(failure)
        case .cancelled:
            wasCancelled = true
        case .skipped:
            break
        }
    }

    mutating func stage(_ scanned: ScannedFolder) {
        audioFiles.append(contentsOf: scanned.audioFiles)
        imageURLs.append(contentsOf: scanned.imageURLs)
        if embeddedArtwork == nil { embeddedArtwork = scanned.embeddedArtwork }
        warnings.append(contentsOf: scanned.warnings)
        failures.append(contentsOf: scanned.failures)
        wasCancelled = wasCancelled || scanned.wasCancelled
        if canRepresentFolder { sourceFolder = scanned.folderURL }
    }
}
