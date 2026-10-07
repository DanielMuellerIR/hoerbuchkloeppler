import AppKit
import ImageIO

enum CoverArtwork {
    static func thumbnail(from data: Data, maximumDimension: Int) -> CGImage? {
        guard !data.isEmpty, data.count <= FFmpegWrapper.maximumCoverByteCount,
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
