import Foundation
import CryptoKit
import Darwin

/// Transportformat ohne Audiodaten. Abschnittsfolge ist bewusst die Arrayfolge.
public struct AudiobookProject: Codable, Sendable {
    public static let currentVersion = 1
    public var formatVersion = currentVersion
    public var sources: [ProjectSource]
    public var sections: [ProjectSection]
    public var metadata: BookMetadata
    public var settings: AudioSettings
    public var coverData: Data?
    public var coverSuppressed: Bool

    public init(formatVersion: Int = currentVersion, sources: [ProjectSource], sections: [ProjectSection],
                metadata: BookMetadata, settings: AudioSettings, coverData: Data?, coverSuppressed: Bool) {
        self.formatVersion = formatVersion; self.sources = sources; self.sections = sections
        self.metadata = metadata; self.settings = settings
        self.coverData = coverData; self.coverSuppressed = coverSuppressed
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, sources, sections, metadata, settings, coverData, coverSuppressed
    }

    /// Tolerant wie `AudioSettings.init(from:)`: Ein fehlendes optionales Feld
    /// (etwa aus einer älteren oder von Hand geschriebenen Datei) bekommt seinen
    /// Default, statt die ganze Projektdatei unlesbar zu machen. Quellen und
    /// Abschnitte bleiben Pflicht — ohne sie gibt es kein Projekt.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decodeIfPresent(Int.self, forKey: .formatVersion) ?? Self.currentVersion
        sources = try values.decode([ProjectSource].self, forKey: .sources)
        sections = try values.decode([ProjectSection].self, forKey: .sections)
        metadata = try values.decodeIfPresent(BookMetadata.self, forKey: .metadata) ?? BookMetadata()
        settings = try values.decodeIfPresent(AudioSettings.self, forKey: .settings) ?? AudioSettings()
        coverData = try values.decodeIfPresent(Data.self, forKey: .coverData)
        coverSuppressed = try values.decodeIfPresent(Bool.self, forKey: .coverSuppressed) ?? false
    }

    /// Nur die Versionsnummer lesen, bevor die vollständige Struktur dekodiert
    /// wird. So bekommt eine Datei einer künftigen Version mit geänderten
    /// Feldern die dokumentierte Meldung statt eines Decoding-Fehlers.
    private struct VersionProbe: Decodable { var formatVersion: Int? }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 48 * 1024 * 1024 else { throw ProjectError.invalid("Projektdatei überschreitet 48 MiB.") }
        let data = try Data(contentsOf: url)
        let declaredVersion = (try? JSONDecoder().decode(VersionProbe.self, from: data))?.formatVersion ?? currentVersion
        guard declaredVersion == currentVersion else { throw ProjectError.invalid("Projektversion \(declaredVersion) wird nicht unterstützt.") }
        let project = try JSONDecoder().decode(Self.self, from: data)
        let ids = Set(project.sources.map(\.id))
        guard ids.count == project.sources.count,
              Set(project.sections.map(\.id)).count == project.sections.count,
              project.sections.allSatisfy({ ids.contains($0.sourceID) && $0.start.isFinite && $0.start >= 0 && $0.duration.isFinite && $0.duration > 0 }),
              (project.coverData?.count ?? 0) <= 32 * 1024 * 1024 else {
            throw ProjectError.invalid("Ungültige Quellen, Abschnitte oder Coverdaten im Projekt.")
        }
        return project
    }
}

public struct BookMetadata: Codable, Equatable, Sendable {
    public var title = ""
    public var author = ""
    public var genre = "Hörbuch"
    public var narrator = ""
    public var series = ""
    public var volumeNumber = ""
    public var language = ""
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case title, author, genre, narrator, series, volumeNumber, language
    }

    /// Jedes Feld einzeln mit Default lesen: Eine additive Erweiterung der
    /// Metadaten darf bestehende `.hkproject`-Dateien nicht unlesbar machen.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BookMetadata()
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? defaults.title
        author = try values.decodeIfPresent(String.self, forKey: .author) ?? defaults.author
        genre = try values.decodeIfPresent(String.self, forKey: .genre) ?? defaults.genre
        narrator = try values.decodeIfPresent(String.self, forKey: .narrator) ?? defaults.narrator
        series = try values.decodeIfPresent(String.self, forKey: .series) ?? defaults.series
        volumeNumber = try values.decodeIfPresent(String.self, forKey: .volumeNumber) ?? defaults.volumeNumber
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? defaults.language
    }
}

public struct ProjectSection: Codable, Sendable {
    public var id: UUID
    public var sourceID: UUID
    public var start: Double
    public var duration: Double
    public var title: String
}

public struct ProjectLocation: Codable, Sendable {
    public var path: String
    public var isRelative: Bool

    public init(url: URL, projectURL: URL) {
        let base = projectURL.deletingLastPathComponent().standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        // Quellen innerhalb des Projektordners reisen mit diesem mit. Externe
        // Quellen bekommen einen eindeutig absoluten Pfad, keine CWD-Abhängigkeit.
        isRelative = path.hasPrefix(base)
        self.path = isRelative ? String(path.dropFirst(base.count)) : path
    }

    public func resolve(from projectURL: URL) -> URL {
        isRelative ? projectURL.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
            : URL(fileURLWithPath: path).standardizedFileURL
    }
}

public struct ProjectSource: Codable, Sendable {
    public var id: UUID
    public var location: ProjectLocation
    public var readLocation: ProjectLocation
    public var sha256: String

    public static func fingerprint(_ url: URL) throws -> String {
        // O_NONBLOCK verhindert, dass ein ausgetauschter FIFO schon beim
        // Öffnen hängen bleibt. Erst der geöffnete Descriptor beweist den Typ.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
            throw ProjectError.invalid("Quelle ist keine reguläre Datei: \(url.lastPathComponent)")
        }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw ProjectError.invalid("Quelle wurde während der Prüfung verändert: \(url.lastPathComponent)")
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct ProjectSourceIssue: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var path: String
    public var reason: String
}

public enum ProjectError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

extension BookMetadata {
    /// MP4 speichert die Sprache als dreistelligen ISO-639-2-Code.
    public static func outputLanguage(_ value: String) throws -> String {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        if code.isEmpty { return "" }
        let language = Locale.LanguageCode(code)
        if language.isISOLanguage, let expanded = language.identifier(.alpha3) { return expanded }
        guard code.range(of: "^[a-z]{3}$", options: .regularExpression) != nil else {
            throw ProjectError.invalid("Sprache als dreistelligen ISO-639-2-Code angeben, z. B. deu oder eng.")
        }
        return code
    }

    public static func validateVolumeNumber(_ value: String) throws {
        guard value.isEmpty || (UInt16(value).map { $0 > 0 } ?? false) else {
            throw ProjectError.invalid("Bandnummer muss leer oder eine Zahl von 1 bis 65535 sein.")
        }
    }
}
