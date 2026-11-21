import Foundation

/// Eine gefundene Datei mit sichtbarem Quellpfad und physischer Lese-URL.
///
/// `source` ist der Pfad, unter dem der Nutzer die Datei sieht. `resolved` ist
/// die reguläre Datei, die AVFoundation und ffmpeg öffnen. Bei gewöhnlichen
/// Dateien sind beide gleich; bei einem Symlink bleibt so dessen bewusst
/// gewählter Name erhalten, ohne den Link selbst an Audio-APIs zu übergeben.
public struct FoundFile: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case audio
        case image
        case unsupported
    }

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "flac", "m4b", "mp4"
    ]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png"]
    private static let chapterContainerExtensions: Set<String> = ["m4b", "mp4"]

    public let source: URL
    public let resolved: URL

    public init(source: URL, resolved: URL) {
        self.source = source
        self.resolved = resolved
    }

    public var readURL: URL { resolved }

    /// Der Typ darf am sichtbaren Namen oder am Ziel erkennbar sein. Ob eine
    /// Datei Kapitelcontainer ist, entscheidet dagegen ausschließlich die
    /// wirklich gelesene Datei.
    public var kind: Kind {
        let extensions = [source.pathExtension, resolved.pathExtension]
            .map { $0.lowercased() }
        if extensions.contains(where: Self.audioExtensions.contains) { return .audio }
        if extensions.contains(where: Self.imageExtensions.contains) { return .image }
        return .unsupported
    }

    public var isChapterContainer: Bool {
        Self.chapterContainerExtensions.contains(resolved.pathExtension.lowercased())
    }

    var isSymbolicLink: Bool {
        source.standardizedFileURL != resolved.standardizedFileURL
    }
}
