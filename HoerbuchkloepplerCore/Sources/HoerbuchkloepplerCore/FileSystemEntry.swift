import Darwin
import Foundation

/// Identifiziert genau einen Verzeichniseintrag. Neben Inode und Volume werden
/// Größe sowie Änderungs-/Statuszeit festgehalten, damit auch eine in-place
/// geänderte Zieldatei nicht mehr als die vom Nutzer bestätigte Datei gilt.
struct FileSystemIdentity: Codable, Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let size: off_t
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusSeconds: Int64
    let statusNanoseconds: Int64

    init(stat information: stat) {
        device = information.st_dev
        inode = information.st_ino
        mode = information.st_mode
        size = information.st_size
        modificationSeconds = Int64(information.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(information.st_mtimespec.tv_nsec)
        statusSeconds = Int64(information.st_ctimespec.tv_sec)
        statusNanoseconds = Int64(information.st_ctimespec.tv_nsec)
    }

    /// Vergleicht genau die Felder, die sich beim Ändern des Datei-INHALTS
    /// zwangsläufig mitändern: Volume, Inode, Größe und Änderungszeit.
    /// Bewusst NICHT dabei sind
    /// - die Statuszeit `st_ctime`: Sie steigt auch bei einem Finder-Tag, einem
    ///   `chmod` oder einem `xattr` durch Spotlight oder Time Machine;
    /// - der Modus `st_mode`: Ein `chmod` ändert die Rechte, nicht den Inhalt.
    ///   Wo der Dateityp zählt, steht daneben eine eigene `S_IFMT`-Prüfung.
    func matchesContentSnapshot(_ other: FileSystemIdentity) -> Bool {
        device == other.device
            && inode == other.inode
            && size == other.size
            && modificationSeconds == other.modificationSeconds
            && modificationNanoseconds == other.modificationNanoseconds
    }

    /// Ein atomarer Rename aktualisiert auf manchen Volumes die Statuszeit des
    /// verschobenen Eintrags. Für die Prüfung NACH `RENAME_SWAP` zählen deshalb
    /// Inhalts-Snapshot und Dateityp, aber weder Statuszeit noch Zugriffsrechte.
    /// Ein paralleles `chmod` ändert den Inhalt nicht und darf Vor- und
    /// Nachprüfung nicht auf unterschiedliche Antworten bringen.
    func matchesDisplacedEntry(_ other: FileSystemIdentity) -> Bool {
        matchesContentSnapshot(other)
            && (mode & mode_t(S_IFMT)) == (other.mode & mode_t(S_IFMT))
    }

    /// Verzeichnisgröße und Zeitstempel ändern sich bei jedem Kind-Eintrag.
    /// Für den Besitz eines Verzeichniseintrags sind deshalb nur Volume, Inode
    /// und der unveränderte Dateityp stabil.
    func matchesDirectoryEntry(_ other: FileSystemIdentity) -> Bool {
        device == other.device
            && inode == other.inode
            && mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && other.mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    /// Inhalt und Zeitstempel einer ffmpeg-Ausgabedatei ändern sich während
    /// der Konvertierung. Volume, Inode und Dateityp müssen dagegen vom
    /// exklusiven Anlegen bis zum Commit unverändert bleiben.
    func matchesRegularFileEntry(_ other: FileSystemIdentity) -> Bool {
        device == other.device
            && inode == other.inode
            && mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && other.mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }
}

enum OutputDestinationSnapshot: Equatable, Sendable {
    case missing
    case existing(FileSystemIdentity)
    case inaccessible(errno: Int32)

    /// Vergleicht zwei Pfad-Snapshots. Finder-Tags, chmod und xattrs können
    /// allein die Statuszeit ändern und sollen keinen Export verwerfen.
    /// Diese Prüfung erkennt keine gleich großen Änderungen mit manuell
    /// zurückgestellter Änderungszeit.
    func matchesContent(of other: OutputDestinationSnapshot) -> Bool {
        switch (self, other) {
        case (.missing, .missing):
            return true
        case (.existing(let mine), .existing(let theirs)):
            return mine.matchesContentSnapshot(theirs)
        case (.inaccessible(let mine), .inaccessible(let theirs)):
            return mine == theirs
        default:
            return false
        }
    }
}

enum FileSystemEntry {
    static func identity(
        at url: URL,
        followSymlink: Bool
    ) -> FileSystemIdentity? {
        var information = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return Darwin.fstatat(
                AT_FDCWD,
                path,
                &information,
                followSymlink ? 0 : AT_SYMLINK_NOFOLLOW
            )
        }
        guard result == 0 else { return nil }
        return FileSystemIdentity(stat: information)
    }

    static func snapshot(
        of url: URL,
        followSymlink: Bool = false
    ) -> OutputDestinationSnapshot {
        if let identity = identity(at: url, followSymlink: followSymlink) {
            return .existing(identity)
        }
        let errorNumber = errno
        return errorNumber == ENOENT || errorNumber == ENOTDIR
            ? .missing
            : .inaccessible(errno: errorNumber)
    }

    static func identity(of descriptor: Int32) -> FileSystemIdentity? {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else { return nil }
        return FileSystemIdentity(stat: information)
    }

    static func identity(of name: String, in descriptor: Int32) -> FileSystemIdentity? {
        var information = stat()
        let result = name.withCString {
            Darwin.fstatat(descriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else { return nil }
        return FileSystemIdentity(stat: information)
    }

    @discardableResult
    static func rename(
        from sourceURL: URL,
        to destinationURL: URL,
        flags: UInt32
    ) -> Int32 {
        sourceURL.path.withCString { source in
            destinationURL.path.withCString { destination in
                Darwin.renameatx_np(
                    AT_FDCWD,
                    source,
                    AT_FDCWD,
                    destination,
                    flags
                )
            }
        }
    }

    /// Gemeinsame Pfadauflösung für Quellprüfung, Ausgabeplanung und Zielsperren.
    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Öffnet genau den benannten Ordner als Deskriptor. `O_DIRECTORY` weist
    /// andere Dateitypen ab. `O_NOFOLLOW` verhindert das Öffnen eines Symlinks
    /// am letzten Pfadbestandteil.
    static func openDirectory(_ url: URL) -> Int32 {
        url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
    }

    /// Entfernt einen leeren Ordnereintrag. Bewusst `rmdir` statt
    /// `removeItem`: Wurde der sichtbare Pfad nach dem gebundenen Leeren
    /// ausgetauscht, bleibt ein Ersatz mit Inhalt stehen, statt rekursiv
    /// gelöscht zu werden.
    @discardableResult
    static func removeEmptyDirectory(_ url: URL) -> Int32 {
        url.withUnsafeFileSystemRepresentation { path in
            path.map(Darwin.rmdir) ?? -1
        }
    }

    static func nonemptyFileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? Int64
        else { return nil }
        return size > 0 ? size : nil
    }

    /// Liest die Einträge des gebundenen Verzeichnisses. Bewusst `openat` auf
    /// „." statt `dup`: `dup` teilt die Dateibeschreibung und damit den
    /// Verzeichnis-Offset, ein zweiter Scan desselben Deskriptors stünde also
    /// schon am Ende und lieferte immer eine leere Liste. `openat` bleibt an
    /// den geprüften Deskriptor gebunden und löst keinen Namen neu auf.
    static func directoryEntryNames(
        descriptor: Int32
    ) -> [String]? {
        let duplicate = ".".withCString {
            Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard duplicate >= 0, let stream = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            return nil
        }
        defer { Darwin.closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                return errno == 0 ? names : nil
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
    }
}
