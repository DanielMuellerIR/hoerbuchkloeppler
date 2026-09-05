import Foundation
import AVFoundation
import Darwin

/// Zähler für tatsächlich ausgeführte Analyseanforderungen. Ein gebündelter
/// AVFoundation-Aufruf lädt drei Eigenschaften; Artwork-Daten bleiben separat.
public struct ImportAnalysisMetrics: Sendable, Codable {
    public var sourceAnalyses = 0
    public var assetLoadRequests = 0
    public var artworkDataRequests = 0
    public var trackLanguageRequests = 0
    public var chapterProcessRequests = 0
}

struct ImportSourceIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    init?(_ url: URL) {
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in
            path.map { fstatat(AT_FDCWD, $0, &info, 0) } ?? -1
        }) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }
}

/// Unveränderlicher Metadaten-Snapshot: AVMetadataItem wird ausschließlich
/// gelesen. Große Bilddaten werden erst bei der tatsächlichen Coversuche geladen.
struct ImportedSourceAnalysis: @unchecked Sendable {
    let file: AudioFile
    let identity: ImportSourceIdentity
    let artworkItems: [AVMetadataItem]
    let bookMetadata: [String: String]

    func isCurrent() -> Bool {
        ImportSourceIdentity(file.url) == identity && ImportSourceIdentity(file.sourceURL) == identity
    }
}

enum SourceAnalysisResult: Sendable {
    case success(ImportedSourceAnalysis)
    case failure(AudioImportFailure)
    case cancelled
}

public final class AudioImportService: @unchecked Sendable {
    private let lock = NSLock()
    private var configuredWorkers = 4
    private var counters = ImportAnalysisMetrics()
    private var artworkCache: [URL: ImportedSourceAnalysis] = [:]

    public init() {}

    /// Begrenzte Parallelität für lokale und langsamere externe Datenträger.
    /// Höhere Werte bleiben auch bei fehlerhaften Settings auf acht begrenzt.
    public var workerLimit: Int {
        get { lock.withLock { configuredWorkers } }
        set { lock.withLock { configuredWorkers = min(8, max(1, newValue)) } }
    }
    public var metrics: ImportAnalysisMetrics { lock.withLock { counters } }
    public func resetMetrics() { lock.withLock { counters = ImportAnalysisMetrics() } }
    func recordChapterRequest() { lock.withLock { counters.chapterProcessRequests += 1 } }

    func analyze(_ file: FoundFile) async -> SourceAnalysisResult {
        guard !Task.isCancelled else { return .cancelled }
        lock.withLock { counters.sourceAnalyses += 1 }
        guard let identity = ImportSourceIdentity(file.readURL),
              ImportSourceIdentity(file.source) == identity else {
            return .failure(AudioImportFailure(sourceURL: file.source, reason: .analysisFailed))
        }
        let asset = AVURLAsset(url: file.readURL)
        return await withTaskCancellationHandler {
            do {
                guard !Task.isCancelled else { return .cancelled }
                lock.withLock { counters.assetLoadRequests += 1 }
                let (tracks, duration, metadata) = try await asset.load(.tracks, .duration, .metadata)
                guard !Task.isCancelled else { return .cancelled }
                guard ImportSourceIdentity(file.readURL) == identity,
                      ImportSourceIdentity(file.source) == identity else {
                    return .failure(AudioImportFailure(sourceURL: file.source, reason: .sourceChanged))
                }
                guard let audioTrack = tracks.first(where: { $0.mediaType == .audio }) else {
                    return .failure(AudioImportFailure(sourceURL: file.source, reason: .noAudioTrack))
                }
                let seconds = CMTimeGetSeconds(duration)
                guard seconds.isFinite, seconds > 0 else {
                    return .failure(AudioImportFailure(sourceURL: file.source, reason: .unreadableDuration))
                }
                let title = await AudioFile.findRobustTag(for: "title", in: metadata)
                    ?? file.source.deletingPathExtension().lastPathComponent
                guard !Task.isCancelled else { return .cancelled }
                guard ImportSourceIdentity(file.readURL) == identity,
                      ImportSourceIdentity(file.source) == identity else {
                    return .failure(AudioImportFailure(sourceURL: file.source, reason: .sourceChanged))
                }
                var bookMetadata = await Self.bookMetadata(from: metadata)
                if bookMetadata["language"] == nil {
                    lock.withLock { counters.trackLanguageRequests += 1 }
                    if let (code, extended) = try? await audioTrack.load(.languageCode, .extendedLanguageTag),
                       let language = extended ?? code, !language.isEmpty, language != "und" {
                        bookMetadata["language"] = language
                    }
                }
                guard !Task.isCancelled else { return .cancelled }
                guard ImportSourceIdentity(file.readURL) == identity,
                      ImportSourceIdentity(file.source) == identity else {
                    return .failure(AudioImportFailure(sourceURL: file.source, reason: .sourceChanged))
                }
                let analysis = ImportedSourceAnalysis(
                    file: AudioFile(foundFile: file, startTime: 0, duration: seconds, chapterTitle: title),
                    identity: identity,
                    artworkItems: metadata.filter(AudioFile.isArtworkItem),
                    bookMetadata: bookMetadata
                )
                lock.withLock { artworkCache[file.readURL] = analysis }
                return .success(analysis)
            } catch {
                if Task.isCancelled { return .cancelled }
                return .failure(AudioImportFailure(sourceURL: file.source, reason: .analysisFailed))
            }
        } onCancel: {
            asset.cancelLoading()
        }
    }

    /// Zusätzliche Buchfelder aus demselben AVFoundation-Snapshot. Die Keys
    /// entsprechen den Ausgabe-Tags und lassen sich ohne GUI-Abhängigkeit in
    /// ein Projekt übernehmen. Ein veränderter Quellpfad liefert keine alten Werte.
    public func metadata(for url: URL) -> [String: String]? {
        guard let analysis = lock.withLock({ artworkCache[url] }), analysis.isCurrent() else { return nil }
        return analysis.bookMetadata
    }

    static func bookMetadata(from items: [AVMetadataItem]) async -> [String: String] {
        let aliases = [
            "narrator": "narrator", "narration": "narrator", "reader": "narrator",
            "composer": "narrator", "%a9wrt": "narrator", "©wrt": "narrator",
            "series": "series", "grouping": "series", "%a9grp": "series", "©grp": "series",
            "volume_number": "volume_number", "disc": "volume_number", "disk": "volume_number",
            "series_part": "volume_number", "language": "language"
        ]
        var result: [String: String] = [:]
        for item in items {
            guard !Task.isCancelled else { return result }
            // Ganze Tag-Namen vergleichen: series_part ist eine Bandnummer und
            // darf nicht versehentlich zugleich als Reihenname gelesen werden.
            let names = [item.commonKey?.rawValue, item.key.map { String(describing: $0) }, item.identifier?.rawValue]
                .compactMap { $0?.lowercased().split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) }
            guard let key = names.compactMap({ aliases[$0] }).first, result[key] == nil else { continue }
            if let value = try? await item.load(.stringValue), !value.isEmpty {
                result[key] = value
            } else if key == "volume_number", names.contains("disk"),
                      let data = try? await item.load(.dataValue), data.count >= 4 {
                // Das native MP4-disk-Atom speichert die Nummer als UInt16 in
                // Big Endian hinter zwei reservierten Bytes, nicht als Text.
                let number = Int(data[data.startIndex + 2]) * 256 + Int(data[data.startIndex + 3])
                if number > 0 { result[key] = String(number) }
            }
        }
        return result
    }

    public func clearCachedArtwork() { lock.withLock { artworkCache.removeAll() } }

    func retainCachedArtwork(for urls: [URL]) {
        let retained = Set(urls)
        lock.withLock { artworkCache = artworkCache.filter { retained.contains($0.key) } }
    }

    func artwork(at url: URL) async -> Data? {
        if let cached = lock.withLock({ artworkCache[url] }) {
            return await artwork(from: cached)
        }
        guard case .success(let analysis) = await analyze(FoundFile(source: url, resolved: url)) else { return nil }
        return await artwork(from: analysis)
    }

    func artwork(from analysis: ImportedSourceAnalysis) async -> Data? {
        guard !Task.isCancelled, analysis.isCurrent() else { return nil }
        for item in analysis.artworkItems {
            guard !Task.isCancelled else { return nil }
            lock.withLock { counters.artworkDataRequests += 1 }
            let data = try? await item.load(.dataValue)
            guard !Task.isCancelled, analysis.isCurrent() else { return nil }
            if let valid = AudioFile.validatedEmbeddedArtworkData(data) { return valid }
        }
        return nil
    }

    /// Höchstens `workerLimit` Aufgaben gleichzeitig. Das Ergebnis behält die
    /// Eingangsreihenfolge auch dann, wenn eine spätere Quelle zuerst fertig ist.
    func orderedMap<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        shouldCancel: @escaping @Sendable () -> Bool,
        operation: @escaping @Sendable (Input) async -> Output
    ) async -> [Output]? {
        guard !shouldCancel(), !Task.isCancelled else { return nil }
        return await withTaskGroup(of: (Int, Output).self) { group in
            var next = 0
            var results = [Output?](repeating: nil, count: inputs.count)
            for _ in 0..<min(workerLimit, inputs.count) {
                let index = next
                group.addTask { (index, await operation(inputs[index])) }
                next += 1
            }
            while let (index, output) = await group.next() {
                if shouldCancel() || Task.isCancelled {
                    group.cancelAll()
                    return nil
                }
                results[index] = output
                if next < inputs.count {
                    let index = next
                    group.addTask { (index, await operation(inputs[index])) }
                    next += 1
                }
            }
            return results.compactMap { $0 }
        }
    }
}
