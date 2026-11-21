import Foundation
import AVFoundation

public struct AudioFile: Identifiable, Equatable, Sendable {
    public var id = UUID()
    /// Physische Lese-URL: die reguläre Datei, aus der AVFoundation und ffmpeg
    /// lesen. Bei einem Symlink ist das dessen aufgelöstes Ziel.
    public let url: URL
    /// Logischer Quellpfad: der Pfad, unter dem der Nutzer die Datei sieht.
    /// Bei einem Symlink der Linkpfad, sonst gleich `url`. Reihenfolge und
    /// Fallback-Kapiteltitel folgen ihm, damit zwei Links auf dasselbe Ziel
    /// unterscheidbar bleiben (Review-Fund 2026-08-17).
    public let sourceURL: URL
    public let duration: TimeInterval
    public let startTime: TimeInterval
    public var chapterTitle: String
    public var name: String { sourceURL.lastPathComponent }

    /// Lädt Dauer und Kapiteltitel einer gewöhnlichen Datei. Für Symlinks
    /// muss der strukturierte `FoundFile`-Initializer benutzt werden.
    public init(url: URL) async {
        let analyzed = await Self.loadDurationAndTitle(readURL: url, visibleURL: url)
        self.url = url
        self.sourceURL = url
        self.startTime = 0
        self.duration = analyzed.duration
        self.chapterTitle = analyzed.title
    }

    /// Lädt aus der physischen Ziel-Datei, behält aber sichtbaren Namen und
    /// Fallback-Titel des Quellpfads bei.
    public init(foundFile: FoundFile) async {
        let analyzed = await Self.loadDurationAndTitle(
            readURL: foundFile.readURL,
            visibleURL: foundFile.source
        )
        self.url = foundFile.readURL
        self.sourceURL = foundFile.source
        self.startTime = 0
        self.duration = analyzed.duration
        self.chapterTitle = analyzed.title
    }

    public init(url: URL, startTime: TimeInterval, duration: TimeInterval,
                chapterTitle: String) {
        self.url = url
        self.sourceURL = url
        self.startTime = AudioFile.sanitizeDuration(startTime)
        self.duration = AudioFile.sanitizeDuration(duration)
        self.chapterTitle = chapterTitle
    }

    public init(foundFile: FoundFile, startTime: TimeInterval,
                duration: TimeInterval, chapterTitle: String) {
        self.url = foundFile.readURL
        self.sourceURL = foundFile.source
        self.startTime = AudioFile.sanitizeDuration(startTime)
        self.duration = AudioFile.sanitizeDuration(duration)
        self.chapterTitle = chapterTitle
    }

    /// Gemeinsame AVFoundation-Analyse für reguläre Dateien und Symlink-Ziele.
    /// CMTime-Werte werden an der Quelle auf endlich und nicht-negativ geklemmt;
    /// unlesbare oder abgebrochene Metadaten fallen auf den sichtbaren Namen zurück.
    private static func loadDurationAndTitle(
        readURL: URL,
        visibleURL: URL
    ) async -> (duration: TimeInterval, title: String) {
        let fallbackTitle = visibleURL.deletingPathExtension().lastPathComponent
        guard !taskCancellationRequested() else { return (0, fallbackTitle) }
        let asset = AVAsset(url: readURL)
        let loadedDuration = try? await asset.load(.duration)
        let duration = sanitizeDuration(loadedDuration.map(CMTimeGetSeconds) ?? 0)
        guard !taskCancellationRequested() else { return (duration, fallbackTitle) }
        let metadata = (try? await asset.load(.metadata)) ?? []
        guard !taskCancellationRequested() else { return (duration, fallbackTitle) }
        let title = await findRobustTag(for: "title", in: metadata) ?? fallbackTitle
        return (duration, title)
    }

    /// Macht eine Sekundenangabe für Berechnungen sicher: NaN/Infinity/negativ → 0.
    static func sanitizeDuration(_ seconds: TimeInterval) -> TimeInterval {
        return (seconds.isFinite && seconds >= 0) ? seconds : 0
    }

    /// Wertet die strukturierte Task-Cancellation über `Task.checkCancellation`
    /// aus, ohne die absichtlich fehlertoleranten Audio-APIs werfend zu machen.
    static func taskCancellationRequested() -> Bool {
        do {
            try Task.checkCancellation()
            return false
        } catch {
            return true
        }
    }

    static func findRobustTag(
        for tagName: String,
        in metadata: [AVMetadataItem]
    ) async -> String? {
        guard !taskCancellationRequested() else { return nil }
        if let commonItem = metadata.first(where: { $0.commonKey?.rawValue == tagName }) {
            let value = try? await commonItem.load(.stringValue)
            guard !taskCancellationRequested() else { return nil }
            if let value, !value.isEmpty {
                return value
            }
        }
        for item in metadata {
            guard !taskCancellationRequested() else { return nil }
            guard let key = item.key else { continue }
            let keyString = String(describing: key).lowercased()
            if keyString.contains(tagName.lowercased()) {
                let value = try? await item.load(.stringValue)
                guard !taskCancellationRequested() else { return nil }
                if let value, !value.isEmpty { return value }
            }
        }
        return nil
    }
}
