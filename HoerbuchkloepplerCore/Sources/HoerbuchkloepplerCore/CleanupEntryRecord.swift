import Darwin
import Foundation

/// Beschreibt den einzigen Nutzdateneintrag, den ein Ausgabeordner löschen darf.
/// Alte JSON-Datensätze konnten zusätzlich eine vor dem Swap notierte
/// Altdatei enthalten. Ohne bestätigte Übernahme ist diese Alternatividentität
/// kein Löschbeleg. Codable liest weiterhin den ursprünglichen Primäreintrag.
struct CleanupEntryRecord: Codable {
    let identity: FileSystemIdentity
    let filename: String
    let stableIdentityOnly: Bool

    func matches(_ current: FileSystemIdentity) -> Bool {
        stableIdentityOnly
            ? identity.matchesRegularFileEntry(current)
            : identity.matchesDisplacedEntry(current)
    }
}

extension CleanupEntryRecord {
    static let markerName = ".entry-identity.json"

    static func write(
        _ identity: FileSystemIdentity,
        in cleanupDirectory: URL,
        filename: String = "entry",
        stableIdentityOnly: Bool = false
    ) throws {
        let data = try JSONEncoder().encode(
            CleanupEntryRecord(
                identity: identity,
                filename: filename,
                stableIdentityOnly: stableIdentityOnly
            ))
        try data.write(
            to: cleanupDirectory.appendingPathComponent(
                markerName
            ),
            options: .atomic
        )
    }

    static func read(
        in cleanupDirectory: URL
    ) -> CleanupEntryRecord? {
        let marker = cleanupDirectory.appendingPathComponent(
            markerName
        )
        let descriptor = marker.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
            information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            information.st_size > 0, information.st_size <= 64 * 1024,
            let data = try? handle.read(upToCount: 64 * 1024 + 1),
            data.count == information.st_size,
            let record = try? JSONDecoder().decode(
                CleanupEntryRecord.self,
                from: data
            ),
            !record.filename.isEmpty,
            !record.filename.contains("/"), !record.filename.contains("\0"),
            ![".", "..", OwnedTemporaryDirectory.tempOwnerFilename, markerName, ".HB_EntryCleanup"]
                .contains(record.filename)
        else { return nil }
        return record
    }

    static func matchesRecordedEntry(
        _ record: CleanupEntryRecord,
        in cleanupDirectory: URL
    ) -> Bool {
        let entry = cleanupDirectory.appendingPathComponent(record.filename)
        switch FileSystemEntry.snapshot(of: entry) {
        case .missing:
            return true
        case .existing(let current):
            return record.matches(current)
        case .inaccessible:
            return false
        }
    }

    private static func matchesRecordedEntry(
        _ record: CleanupEntryRecord,
        directoryDescriptor: Int32
    ) -> Bool {
        guard let current = FileSystemEntry.identity(of: record.filename, in: directoryDescriptor)
        else {
            return errno == ENOENT
        }
        return record.matches(current)
    }

    /// Entfernt aus einem Ausgabe-Cleanup-Ordner ausschließlich die drei
    /// aufgezeichneten Einträge. Zusätzliche Dateien sind Recovery-Daten und
    /// verhindern jede automatische Löschung des Ordners.
    static func removeContents(
        descriptor: Int32,
        record: CleanupEntryRecord,
        beforeEntryQuarantine: ((Int32) -> Void)? = nil
    ) -> Bool {
        guard let names = FileSystemEntry.directoryEntryNames(descriptor: descriptor) else {
            return false
        }
        // Der feste Zwischenname ist Teil des Crash-Protokolls: Stirbt der
        // Prozess nach dem Rename, erkennt der nächste Sweep genau diesen
        // Zustand und prüft dessen Inode erneut gegen denselben Datensatz.
        let quarantineName = ".HB_EntryCleanup"
        let allowed = Set([
            OwnedTemporaryDirectory.tempOwnerFilename,
            markerName,
            record.filename,
            quarantineName,
        ])
        let hasEntry = names.contains(record.filename)
        let hasQuarantine = names.contains(quarantineName)
        guard Set(names).isSubset(of: allowed),
            !(hasEntry && hasQuarantine)
        else { return false }

        var movedDuringThisCall = false
        if hasEntry {
            guard
                matchesRecordedEntry(
                    record,
                    directoryDescriptor: descriptor
                )
            else { return false }
            beforeEntryQuarantine?(descriptor)
            let quarantined = record.filename.withCString { source in
                quarantineName.withCString { destination in
                    Darwin.renameatx_np(
                        descriptor,
                        source,
                        descriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard quarantined == 0 else { return false }
            movedDuringThisCall = true
        }
        if hasEntry || hasQuarantine {
            guard let moved = FileSystemEntry.identity(of: quarantineName, in: descriptor),
                record.matches(moved)
            else {
                // Der Name wurde nach der Vorprüfung ausgetauscht. Der atomar
                // quarantänisierte fremde Eintrag wird zurückgestellt; falls
                // dort inzwischen wieder etwas liegt, bleibt er unter dem
                // aufgezeichneten Recovery-Zwischennamen erhalten.
                if movedDuringThisCall {
                    _ = quarantineName.withCString { source in
                        record.filename.withCString { destination in
                            Darwin.renameatx_np(
                                descriptor,
                                source,
                                descriptor,
                                destination,
                                UInt32(RENAME_EXCL)
                            )
                        }
                    }
                }
                return false
            }
            guard
                quarantineName.withCString({
                    Darwin.unlinkat(descriptor, $0, 0)
                }) == 0
            else { return false }
        }
        // Erst erneut nachsehen, dann die Besitzmarken entfernen: Ist seit dem
        // ersten Scan etwas Fremdes dazugekommen, sind das Recovery-Daten. Der
        // Ordner bleibt dann samt `.owner-pid` stehen, sonst könnte ihn kein
        // späterer Lauf je wieder als eigenen erkennen.
        guard let remaining = FileSystemEntry.directoryEntryNames(descriptor: descriptor),
            Set(remaining).isSubset(of: [
                markerName,
                OwnedTemporaryDirectory.tempOwnerFilename,
            ])
        else { return false }
        for marker in remaining {
            guard
                marker.withCString({
                    Darwin.unlinkat(descriptor, $0, 0)
                }) == 0
            else { return false }
        }
        return FileSystemEntry.directoryEntryNames(descriptor: descriptor)?.isEmpty == true
    }
}
