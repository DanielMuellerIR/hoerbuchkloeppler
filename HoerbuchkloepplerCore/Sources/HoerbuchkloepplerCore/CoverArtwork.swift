import AppKit
import Darwin
import ImageIO

public enum CoverArtwork {
    public static let maximumByteCount = 32 * 1024 * 1024

    /// Liest nur einen bereits geöffneten regulären Eintrag, begrenzt die
    /// Eingabegröße und prüft danach einen kleinen ImageIO-Decode. `O_NONBLOCK`
    /// verhindert, dass eine nach der Auswahl eingesetzte FIFO den Start hält.
    static func readFile(
        at url: URL,
        expectedIdentity: FileSystemIdentity? = nil,
        isCancelled: () -> Bool = { false }
    ) -> Data? {
        guard !isCancelled() else { return nil }
        let resolved = url.resolvingSymlinksInPath()
        guard !isCancelled() else { return nil }
        let descriptor = resolved.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_size > 0,
              before.st_size <= off_t(maximumByteCount) else { return nil }
        let openedIdentity = FileSystemIdentity(stat: before)
        if let expectedIdentity, expectedIdentity != openedIdentity { return nil }

        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= maximumByteCount {
            guard !isCancelled() else { return nil }
            let remaining = maximumByteCount + 1 - data.count
            let count = buffer.withUnsafeMutableBytes { storage in
                Darwin.read(
                    descriptor,
                    storage.baseAddress,
                    min(storage.count, remaining)
                )
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            data.append(contentsOf: buffer.prefix(count))
        }

        var after = stat()
        // Gemeinsames Inhaltsprädikat statt eines eigenen Feldvergleichs; die
        // gelesene Bytezahl gegen `st_size` bleibt als eigene Zusicherung daneben.
        guard data.count <= maximumByteCount,
              data.count == Int(before.st_size),
              Darwin.fstat(descriptor, &after) == 0,
              FileSystemIdentity(stat: before).matchesContentSnapshot(FileSystemIdentity(stat: after)),
              !isCancelled(),
              thumbnail(from: data, maximumDimension: 32) != nil,
              !isCancelled() else { return nil }
        return data
    }

    static func thumbnail(from data: Data, maximumDimension: Int) -> CGImage? {
        guard !data.isEmpty, data.count <= maximumByteCount,
              maximumDimension > 0,
              let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
              ), CGImageSourceGetCount(source) > 0 else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    static func preview(from data: Data) -> NSImage? {
        guard let thumbnail = thumbnail(from: data, maximumDimension: 2_000) else { return nil }
        return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
    }
}

struct PreparedEmbeddedArtwork: Sendable {
    let data: Data
    let thumbnail: CGImage

    init?(_ data: Data) {
        guard let thumbnail = CoverArtwork.thumbnail(from: data, maximumDimension: 2_000) else { return nil }
        self.data = data
        self.thumbnail = thumbnail
    }

    @MainActor
    var image: NSImage {
        NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
    }
}

struct PreparedImportArtwork: Sendable {
    var embedded: PreparedEmbeddedArtwork?
    var loose: ConversionSession.PreparedCover?

    static func load(embedded: Data?, images: [URL]) async -> Self {
        guard embedded != nil || !images.isEmpty else { return Self() }
        let task = Task.detached {
            let thumbnail = embedded.flatMap(PreparedEmbeddedArtwork.init)
            let loose = largestImage(in: images).flatMap(ConversionSession.PreparedCover.init(url:))
            return Self(embedded: thumbnail, loose: loose)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func largestImage(in urls: [URL]) -> URL? {
        var selected: (url: URL, size: Int)?
        for url in urls {
            guard !Task.isCancelled else { return nil }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > (selected?.size ?? -1) {
                selected = (url, size)
            }
        }
        return selected?.url
    }
}
