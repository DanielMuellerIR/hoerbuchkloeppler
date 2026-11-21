import Darwin
import Foundation

enum CLIDestination {
    /// Der Fallback speichert neben dem sichtbaren Quellpfad. Nur sein
    /// Elternverzeichnis wird physisch aufgelöst.
    static func resolve(
        option: String?,
        sourceURL: URL,
        title: String,
        createDirectories: Bool = true
    ) throws -> URL {
        guard let option else {
            let sourceParent = sourceURL.standardizedFileURL
                .deletingLastPathComponent().resolvingSymlinksInPath()
            return sourceParent.appendingPathComponent("\(title).m4b")
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: option,
            isDirectory: &isDirectory
        )
        if exists && isDirectory.boolValue {
            let outputDirectory = URL(fileURLWithPath: option)
                .standardizedFileURL.resolvingSymlinksInPath()
            return outputDirectory.appendingPathComponent("\(title).m4b")
        }
        guard option.lowercased().hasSuffix(".m4b") else {
            throw reportedFailure(
                "❌ --output muss ein existierender Ordner oder ein .m4b-Pfad sein: \(option)"
            )
        }
        let target = URL(fileURLWithPath: option).standardizedFileURL
        do {
            if createDirectories {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
        } catch {
            throw reportedFailure(
                "❌ Ausgabeordner konnte nicht angelegt werden: \(error.localizedDescription)"
            )
        }
        let resolvedParent = target.deletingLastPathComponent()
            .resolvingSymlinksInPath()
        return resolvedParent.appendingPathComponent(target.lastPathComponent)
    }

    /// Macht aus einem (Metadaten-)Titel einen sicheren Dateinamen: Pfad- und
    /// Steuerzeichen (`/`, `:`, `\`, Umbrüche) werden durch `-` ersetzt, Rand-
    /// Whitespace/Punkte entfernt und der UTF-8-Name auf APFS/HFS-kompatible
    /// Länge begrenzt. Sonst landete der Output bei einem Titel mit `/` im
    /// falschen Verzeichnis oder scheiterte erst tief im Core mit ENAMETOOLONG.
    static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\\n\r\t").union(.controlCharacters)
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .").union(.whitespacesAndNewlines))
        guard !cleaned.isEmpty else { return "Hoerbuch" }

        // NAME_MAX beträgt auf den unterstützten macOS-Dateisystemen 255 Byte.
        // Neben `.m4b` bleibt Platz für den größtmöglichen Split-Suffix
        // `-<Int.max>`. Zeichen werden nie mitten in ihrer UTF-8-Folge getrennt.
        let reservedByteCount = ".m4b".utf8.count + 1 + String(Int.max).utf8.count
        let maximumBaseByteCount = Int(NAME_MAX) - reservedByteCount
        var truncated = ""
        var usedByteCount = 0
        for character in cleaned {
            let byteCount = String(character).utf8.count
            guard usedByteCount + byteCount <= maximumBaseByteCount else { break }
            truncated.append(character)
            usedByteCount += byteCount
        }
        let safe = truncated.trimmingCharacters(
            in: CharacterSet(charactersIn: " .").union(.whitespacesAndNewlines)
        )
        return safe.isEmpty ? "Hoerbuch" : safe
    }
}
