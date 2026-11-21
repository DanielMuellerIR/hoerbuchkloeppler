import Darwin
import Foundation

enum OwnedTemporaryDirectory {
    static let tempOwnerFilename = ".owner-pid"

    enum Contents {
        case scratch
        case legacyScratch
        case emptyStaging
        case recordedOutput(CleanupEntryRecord)
    }

    struct RemovalCheckpoints {
        var beforeQuarantine: (() -> Void)?
        var beforeBoundRemoval: (() -> Void)?
        var beforeRecordedEntryQuarantine: ((Int32) -> Void)?
    }

    static func create(
        _ url: URL,
        ownerPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) throws {
        let created = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return Darwin.mkdir(path, mode_t(0o700))
        }
        guard created == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let owner = String(ownerPID)
        do {
            try owner.write(
                to: url.appendingPathComponent(tempOwnerFilename),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            // Das exklusiv erzeugte Blatt ist bei fehlgeschlagenem Marker noch
            // leer. `rmdir` kann deshalb keine untergeschobenen Inhalte löschen.
            _ = FileSystemEntry.removeEmptyDirectory(url)
            throw error
        }
    }

    static func ownerPID(_ url: URL) -> pid_t? {
        let marker = url.appendingPathComponent(tempOwnerFilename)
        guard let text = try? String(contentsOf: marker, encoding: .utf8),
            let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            pid > 0
        else { return nil }
        return pid_t(pid)
    }

    static func ownerPID(
        descriptor: Int32
    ) -> pid_t? {
        let markerDescriptor = tempOwnerFilename.withCString {
            Darwin.openat(
                descriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard markerDescriptor >= 0 else { return nil }
        defer { _ = Darwin.close(markerDescriptor) }
        var information = stat()
        guard Darwin.fstat(markerDescriptor, &information) == 0,
            information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            information.st_size > 0,
            information.st_size <= 32
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(information.st_size))
        let count = bytes.withUnsafeMutableBytes {
            Darwin.read(markerDescriptor, $0.baseAddress, $0.count)
        }
        guard count == bytes.count,
            let text = String(bytes: bytes, encoding: .utf8),
            let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            pid > 0
        else { return nil }
        return pid_t(pid)
    }

    static func hasLiveOwner(_ url: URL) -> Bool {
        guard let pid = ownerPID(url) else { return false }
        return Darwin.kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    static func matches(_ url: URL, identity: FileSystemIdentity, owner: pid_t) -> Bool {
        guard let current = FileSystemEntry.identity(at: url, followSymlink: false) else {
            return false
        }
        return identity.matchesDirectoryEntry(current) && ownerPID(url) == owner
    }

    /// Entfernt Inhalte ausschließlich relativ zu einem geöffneten
    /// Verzeichnis-Deskriptor. Weder Symlinks noch ein später am sichtbaren Pfad
    /// eingesetztes Ersatzverzeichnis werden dabei rekursiv verfolgt.
    private static func removeDirectoryContentsBound(to descriptor: Int32) -> Bool {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, let stream = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            return false
        }
        defer { Darwin.closedir(stream) }
        let directoryDescriptor = Darwin.dirfd(stream)

        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else { return errno == 0 }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }

            var information = stat()
            let inspected = name.withCString {
                Darwin.fstatat(
                    directoryDescriptor,
                    $0,
                    &information,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard inspected == 0 else { return false }
            if information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                let child = name.withCString {
                    Darwin.openat(
                        directoryDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard child >= 0 else { return false }
                let emptied = removeDirectoryContentsBound(to: child)
                _ = Darwin.close(child)
                guard emptied,
                    name.withCString({
                        Darwin.unlinkat(directoryDescriptor, $0, AT_REMOVEDIR)
                    }) == 0
                else { return false }
            } else {
                guard
                    name.withCString({
                        Darwin.unlinkat(directoryDescriptor, $0, 0)
                    }) == 0
                else { return false }
            }
        }
    }

    private static func isKnownScratchName(_ name: String) -> Bool {
        switch name {
        case "analysis.txt", "audio_list.txt", "chapters.txt", "cover.img", "audio.wav",
            "segment.m4a":
            return true
        default:
            guard name.hasPrefix("seg_") else { return false }
            let parts = name.dropFirst("seg_".count).split(separator: ".", maxSplits: 1)
            guard parts.count == 2, let index = Int(parts[0]), index >= 0 else { return false }
            return String(index) == parts[0] && (parts[1] == "wav" || parts[1] == "m4a")
        }
    }

    private static func removeKnownFiles(
        from descriptor: Int32,
        allowing isKnownPayload: (String) -> Bool
    ) -> Bool {
        guard let names = FileSystemEntry.directoryEntryNames(descriptor: descriptor),
            names.allSatisfy({ $0 == tempOwnerFilename || isKnownPayload($0) }),
            names.allSatisfy({
                let entry = FileSystemEntry.identity(of: $0, in: descriptor)
                return entry.map { $0.mode & mode_t(S_IFMT) == mode_t(S_IFREG) } ?? false
            })
        else { return false }

        for name in names where name != tempOwnerFilename {
            guard name.withCString({ Darwin.unlinkat(descriptor, $0, 0) }) == 0 else {
                return false
            }
        }
        guard let remaining = FileSystemEntry.directoryEntryNames(descriptor: descriptor),
            remaining.allSatisfy({ $0 == tempOwnerFilename })
        else { return false }
        guard remaining.contains(tempOwnerFilename) else { return true }
        return tempOwnerFilename.withCString { Darwin.unlinkat(descriptor, $0, 0) } == 0
    }

    static func remove(
        _ url: URL,
        expectedIdentity: FileSystemIdentity,
        expectedOwnerPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        contents: Contents = .scratch,
        checkpoints: RemovalCheckpoints = RemovalCheckpoints()
    ) {
        guard matches(url, identity: expectedIdentity, owner: expectedOwnerPID) else { return }
        let quarantine: URL
        if case .legacyScratch = contents {
            // Der Ordner liegt bereits unter einem Quarantänenamen. Bei
            // unbekanntem Inhalt bleibt er an genau diesem Pfad erhalten.
            quarantine = url
        } else {
            checkpoints.beforeQuarantine?()
            quarantine = url.deletingLastPathComponent().appendingPathComponent(
                "\(OutputArtifactNames.directoryCleanupPrefix)\(expectedOwnerPID)-\(UUID().uuidString)"
            )
            guard
                FileSystemEntry.rename(
                    from: url,
                    to: quarantine,
                    flags: UInt32(RENAME_EXCL)
                ) == 0
            else { return }
            guard matches(quarantine, identity: expectedIdentity, owner: expectedOwnerPID) else {
                // Stellt einen fremden Eintrag zurück, sofern der alte Name frei ist.
                FileSystemEntry.rename(from: quarantine, to: url, flags: UInt32(RENAME_EXCL))
                return
            }
        }
        checkpoints.beforeBoundRemoval?()
        let descriptor = FileSystemEntry.openDirectory(quarantine)
        guard descriptor >= 0 else { return }
        defer { _ = Darwin.close(descriptor) }
        guard let bound = FileSystemEntry.identity(of: descriptor),
            expectedIdentity.matchesDirectoryEntry(bound)
        else { return }
        let emptied: Bool
        switch contents {
        case .scratch:
            emptied = removeDirectoryContentsBound(to: descriptor)
        case .legacyScratch:
            emptied = removeKnownFiles(from: descriptor, allowing: isKnownScratchName)
        case .emptyStaging:
            emptied = removeKnownFiles(from: descriptor, allowing: { _ in false })
        case .recordedOutput(let record):
            emptied = CleanupEntryRecord.removeContents(
                descriptor: descriptor,
                record: record,
                beforeEntryQuarantine: checkpoints.beforeRecordedEntryQuarantine
            )
        }
        guard emptied,
            let visible = FileSystemEntry.identity(at: quarantine, followSymlink: false),
            expectedIdentity.matchesDirectoryEntry(visible)
        else { return }
        // `rmdir` ist absichtlich nicht rekursiv: Wurde der sichtbare Pfad nach
        // dem gebundenen Leeren ausgetauscht, bleibt ein Ersatz mit Inhalt stehen.
        _ = FileSystemEntry.removeEmptyDirectory(quarantine)
    }

    static func cleanupOldTempDirectories() {
        cleanupOldTempDirectories(
            in: URL(fileURLWithPath: NSTemporaryDirectory()),
            now: Date()
        )
    }

    static func cleanupOldTempDirectories(in tempDir: URL, now: Date) {
        let fileManager = FileManager.default
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: tempDir, includingPropertiesForKeys: [.creationDateKey], options: [])
        else { return }
        let oneDayAgo = now.addingTimeInterval(-24 * 3600)

        for url in contents {
            let name = url.lastPathComponent
            let isTempName = ["HB_Temp_", "HB_Loudness_"].contains { prefix in
                name.hasPrefix(prefix)
                    && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
            }
            let cleanupPrefix = OutputArtifactNames.directoryCleanupPrefix
            let cleanupSuffix =
                name.hasPrefix(cleanupPrefix)
                ? String(name.dropFirst(cleanupPrefix.count)) : ""
            let cleanupParts = cleanupSuffix.split(separator: "-", maxSplits: 1)
            let cleanupOwner = cleanupParts.first.flatMap { pid_t($0) }
            let isCleanupName =
                cleanupParts.count == 2
                && cleanupOwner != nil
                && UUID(uuidString: String(cleanupParts[1])) != nil
            guard isTempName || isCleanupName,
                let resourceValues = try? url.resourceValues(forKeys: [.creationDateKey]),
                let creationDate = resourceValues.creationDate,
                creationDate < oneDayAgo,
                let identity = FileSystemEntry.identity(at: url, followSymlink: false),
                identity.mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                let owner = ownerPID(url),
                !isCleanupName || cleanupOwner == owner
            else { continue }
            // Nur ESRCH beweist, dass der markierte Besitzer nicht mehr lebt.
            guard Darwin.kill(owner, 0) != 0, errno == ESRCH else { continue }
            let contents: Contents
            switch FileSystemEntry.snapshot(
                of: url.appendingPathComponent(CleanupEntryRecord.markerName))
            {
            case .existing:
                // Ausgabe-Quarantänen dürfen auch nach einem Absturz nur ihren
                // aufgezeichneten Eintrag verlieren. Fremde Recovery-Daten
                // und unlesbare Besitznachweise bleiben erhalten.
                guard let record = CleanupEntryRecord.read(in: url) else { continue }
                contents = .recordedOutput(record)
            case .missing:
                // Ältere .HB_Cleanup_-Namen wurden auch für Ausgaben verwendet.
                // Ohne Datensatz darf ein unklarer Rest nicht rekursiv weg.
                contents = isCleanupName ? .legacyScratch : .scratch
            case .inaccessible:
                continue
            }
            remove(
                url,
                expectedIdentity: identity,
                expectedOwnerPID: owner,
                contents: contents
            )
        }
    }
}

extension FFmpegWrapper {
    public static func cleanupOldTempDirectories() {
        OwnedTemporaryDirectory.cleanupOldTempDirectories()
    }
}
