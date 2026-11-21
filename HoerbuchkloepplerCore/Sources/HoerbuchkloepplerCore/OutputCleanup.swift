import Darwin
import Foundation

enum OutputCleanup {
    struct FileRemovalCheckpoints {
        var beforeQuarantine: (() -> Void)?
        var afterQuarantine: ((URL) -> Void)?
        var beforeRestore: (() -> Void)?
    }

    /// Entfernt eine eigene Partial-Datei über einen zufälligen
    /// Quarantänenamen. Nach dem atomaren Rename wird der am Inode haftende
    /// Besitzer-Marker erneut geprüft; ein ausgetauschter Eintrag wird
    /// zurückgestellt und bleibt unangetastet.
    @discardableResult
    static func removeLegacyOutput(
        _ url: URL,
        expectedOwnership: StagingOwnership? = nil,
        log: @Sendable (String) -> Void = { _ in },
        checkpoints: FileRemovalCheckpoints = FileRemovalCheckpoints()
    ) -> Bool {
        if FileSystemEntry.snapshot(of: url) == .missing { return true }
        let owner: pid_t
        let persistentMarker: Bool
        let createdIdentity: FileSystemIdentity?
        if let expectedOwnership {
            owner = expectedOwnership.ownerPID
            persistentMarker = expectedOwnership.hasPersistentMarker
            createdIdentity = expectedOwnership.identity
        } else if let parsedOwner = OutputArtifactNames.stagedOutputOwnerPID(url) {
            owner = parsedOwner
            persistentMarker = true
            createdIdentity = nil
        } else {
            log(
                "Staging-Eintrag hat keine gültige Besitzer-Markierung und bleibt liegen: \(url.path)"
            )
            return false
        }
        guard case .existing(let current) = FileSystemEntry.snapshot(of: url),
            current.mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            createdIdentity?.matchesRegularFileEntry(current) ?? true,
            !persistentMarker
                || OutputStaging.hasOwnerMarker(
                    url,
                    expectedOwnerPID: owner
                )
        else {
            log(
                "Staging-Eintrag hat keine gültige Besitzer-Markierung oder gehört nicht mehr zu diesem Lauf und bleibt liegen: \(url.path)"
            )
            return false
        }
        return quarantineAndRemoveRegularFile(
            url,
            expectedIdentity: current,
            cleanupPrefix: OutputArtifactNames.stagingCleanupPrefix,
            ownerPID: owner,
            log: log,
            checkpoints: checkpoints
        )
    }

    @discardableResult
    static func removeProtectedOutput(
        _ url: URL,
        ownership: StagingOwnership,
        log: @Sendable (String) -> Void = { _ in }
    ) -> Bool {
        guard let directory = ownership.protectedDirectory,
            let directoryIdentity = ownership.protectedDirectoryIdentity
        else {
            return removeLegacyOutput(
                url,
                expectedOwnership: ownership,
                log: log
            )
        }
        if FileSystemEntry.snapshot(of: directory) == .missing { return true }
        if FileSystemEntry.snapshot(of: url) == .missing {
            return removeProtectedStagingDirectoryBound(
                directory,
                identity: directoryIdentity,
                ownership: ownership
            )
        }
        guard let current = FileSystemEntry.identity(at: url, followSymlink: false),
            ownership.matches(current, at: url)
        else {
            log(
                "Geschütztes Staging wurde ausgetauscht und bleibt als Recovery-Rest liegen: \(directory.path)"
            )
            return false
        }
        return removeProtectedStagingDirectoryBound(
            directory,
            identity: directoryIdentity,
            ownership: ownership
        )
    }

    @discardableResult
    static func removeProtectedContainer(
        ownership: StagingOwnership
    ) -> Bool {
        guard let directory = ownership.protectedDirectory,
            let directoryIdentity = ownership.protectedDirectoryIdentity
        else {
            return true
        }
        return removeProtectedStagingDirectoryBound(
            directory,
            identity: directoryIdentity,
            ownership: ownership
        )
    }

    /// Der aktive Lauf löscht seinen geschützten Arbeitsordner direkt über
    /// einen geöffneten Verzeichnis-Deskriptor. Bei einem vorübergehenden
    /// Fehler bleibt derselbe Pfad registriert und kann am Laufende erneut
    /// versucht werden; eine zusätzliche Recovery-Datei bleibt unangetastet.
    @discardableResult
    private static func removeProtectedStagingDirectoryBound(
        _ directory: URL,
        identity: FileSystemIdentity,
        ownership: StagingOwnership
    ) -> Bool {
        if FileSystemEntry.snapshot(of: directory) == .missing { return true }
        guard
            OwnedTemporaryDirectory.matches(
                directory, identity: identity, owner: ownership.ownerPID)
        else {
            return false
        }
        let descriptor = FileSystemEntry.openDirectory(directory)
        guard descriptor >= 0 else { return false }
        guard let bound = FileSystemEntry.identity(of: descriptor),
            identity.matchesDirectoryEntry(bound),
            OwnedTemporaryDirectory.ownerPID(descriptor: descriptor) == ownership.ownerPID
        else {
            _ = Darwin.close(descriptor)
            return false
        }
        let emptied = CleanupEntryRecord.removeContents(
            descriptor: descriptor,
            record: ownership.cleanupEntryRecord
        )
        _ = Darwin.close(descriptor)
        guard emptied,
            let stillVisible = FileSystemEntry.identity(
                at: directory,
                followSymlink: false
            ),
            identity.matchesDirectoryEntry(stillVisible)
        else {
            return false
        }
        let removed = FileSystemEntry.removeEmptyDirectory(directory)
        return removed == 0 || errno == ENOENT
    }

    static func preserveRecoveryEntry(
        from sourceURL: URL,
        for finalURL: URL,
        renameOperation: (URL, URL, UInt32) -> Int32
    ) -> URL? {
        for _ in 0..<4 {
            let recoveryURL = OutputArtifactNames.recoveryOutputURL(for: finalURL)
            if renameOperation(sourceURL, recoveryURL, UInt32(RENAME_EXCL)) == 0 {
                return recoveryURL
            }
            if errno != EEXIST { return nil }
        }
        return nil
    }

    /// Entfernt verwaiste Staging-Dateien früherer Läufe für genau dieses Ziel.
    /// Verwaist = die im Namen vermerkte Besitzer-PID lebt nicht mehr. Dateien
    /// eines lebenden Prozesses (paralleler Lauf auf dasselbe Ziel) und Namen
    /// ohne PID-Marke bleiben unangetastet.
    static func removeOrphans(
        for finalURL: URL,
        caseSensitiveNames: Bool? = nil,
        log: @Sendable (String) -> Void = { _ in },
        beforeUnlink: ((URL) -> Void)? = nil
    ) {
        let fileManager = FileManager.default
        let parent = finalURL.deletingLastPathComponent()
        removeOrphanedQuarantines(in: parent, log: log)
        let basename = OutputArtifactNames.stagingBasename(for: finalURL)
        let prefix = ".\(basename).partial-"
        let expectedExtension =
            finalURL.pathExtension.isEmpty
            ? "m4b" : finalURL.pathExtension
        // Basisname und Endung müssen NACH DERSELBEN Regel verglichen werden,
        // und zwar nach der des Volumes: Auf einem case-insensitiven Volume
        // (macOS-Standard) sind `Buch.M4B` und `Buch.m4b` dasselbe Ziel, auf
        // einem case-sensitiven zwei verschiedene.
        // Liefert das Volume die Eigenschaft nicht (bei Netz-/FUSE-Mounts
        // möglich), gilt das macOS-Standardverhalten: case-insensitiv.
        let caseSensitive =
            caseSensitiveNames
            ?? (try? parent.resourceValues(
                forKeys: [.volumeSupportsCaseSensitiveNamesKey]
            ))?.volumeSupportsCaseSensitiveNames
            ?? false
        func sameName(_ candidate: String, _ expected: String) -> Bool {
            caseSensitive
                ? candidate == expected
                : candidate.compare(expected, options: .caseInsensitive) == .orderedSame
        }
        func startsWithPrefix(_ candidate: String) -> Bool {
            caseSensitive
                ? candidate.hasPrefix(prefix)
                : candidate.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
        }
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil,
                options: []
            )
        else { return }
        for url in contents
        where startsWithPrefix(url.lastPathComponent)
            && sameName(url.pathExtension, expectedExtension)
        {
            guard let owner = OutputArtifactNames.stagedOutputOwnerPID(url) else { continue }
            guard Darwin.kill(owner, 0) != 0, errno == ESRCH else { continue }
            // Nur ein vom Erzeuger exklusiv angelegter und am Inode markierter
            // Eintrag ist unsere Altlast. Ein fremder Ersatz oder eine nach
            // fehlgeschlagenem Rollback verdrängte Zieldatei bleibt erhalten.
            guard
                OutputStaging.hasOwnerMarker(
                    url,
                    expectedOwnerPID: owner
                )
            else {
                log("Unmarkierter Staging-Eintrag bleibt liegen: \(url.path)")
                continue
            }
            // `contentsOfDirectory` liefert auch Ordner. Nie rekursiv löschen;
            // den liegengebliebenen Eintrag aber sichtbar melden.
            guard
                (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                    .isRegularFile == true
            else {
                log("Staging-Eintrag ist keine reguläre Datei und bleibt liegen: \(url.path)")
                continue
            }
            // Die Entfernung prüft Besitzer und Dateityp nach der Auswahl erneut.
            beforeUnlink?(url)
            removeLegacyOutput(url, log: log)
        }
    }

    /// Entfernt nach einem Prozessabsturz zurückgebliebene, exklusiv
    /// angelegte Cleanup-Verzeichnisse neben einem Ausgabeziel. Der exakte Name,
    /// die Besitzerdatei und ESRCH müssen gemeinsam einen toten Lauf belegen.
    static func removeOrphanedQuarantines(
        in parent: URL,
        log: @Sendable (String) -> Void = { _ in }
    ) {
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil
            )
        else { return }
        for url in contents {
            guard
                let prefix = OutputArtifactNames.orphanDirectoryPrefixes.first(where: {
                    url.lastPathComponent.hasPrefix($0)
                })
            else { continue }
            let suffix = url.lastPathComponent.dropFirst(prefix.count)
            let parts = suffix.split(separator: "-", maxSplits: 1)
            guard parts.count == 2,
                let owner = pid_t(parts[0]),
                owner > 0,
                UUID(uuidString: String(parts[1])) != nil,
                let identity = FileSystemEntry.identity(at: url, followSymlink: false),
                identity.mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                OwnedTemporaryDirectory.ownerPID(url) == owner
            else { continue }
            guard Darwin.kill(owner, 0) != 0, errno == ESRCH else { continue }
            guard let entryRecord = CleanupEntryRecord.read(in: url),
                CleanupEntryRecord.matchesRecordedEntry(
                    entryRecord,
                    in: url
                )
            else {
                log(
                    "Cleanup-Rest enthält keinen eindeutig eigenen Eintrag und bleibt liegen: \(url.path)"
                )
                continue
            }
            OwnedTemporaryDirectory.remove(
                url,
                expectedIdentity: identity,
                expectedOwnerPID: owner,
                contents: .recordedOutput(entryRecord)
            )
            if FileSystemEntry.snapshot(of: url) != .missing {
                log("Verwaister Cleanup-Rest konnte nicht entfernt werden: \(url.path)")
            }
        }
    }

    /// Quarantänisiert eine beim Swap verdrängte, vollständig identifizierte
    /// Altdatei. Ein Austausch vor dem Rename bleibt am Ursprung; ein Austausch
    /// danach fällt bei der erneuten Identitätsprüfung auf und wird zurückgestellt.
    @discardableResult
    static func removeDisplacedOutput(
        _ url: URL,
        expectedIdentity: FileSystemIdentity,
        cleanupParent: URL? = nil,
        log: @Sendable (String) -> Void = { _ in },
        checkpoints: FileRemovalCheckpoints = FileRemovalCheckpoints()
    ) -> Bool {
        guard case .existing(let current) = FileSystemEntry.snapshot(of: url),
            expectedIdentity.matchesDisplacedEntry(current)
        else {
            if FileSystemEntry.snapshot(of: url) == .missing { return true }
            log("Verdrängte Ausgabe wurde ausgetauscht und bleibt liegen: \(url.path)")
            return false
        }
        return quarantineAndRemoveRegularFile(
            url,
            expectedIdentity: expectedIdentity,
            cleanupPrefix: OutputArtifactNames.displacedCleanupPrefix,
            ownerPID: ProcessInfo.processInfo.processIdentifier,
            cleanupParent: cleanupParent,
            log: log,
            checkpoints: checkpoints
        )
    }

    /// Verschiebt eine geprüfte Einzeldatei in ein exklusiv angelegtes
    /// 0700-Cleanup-Verzeichnis. Danach muss ihre Identität erneut passen.
    /// Die gebundene Bereinigung entfernt nur den aufgezeichneten Eintrag.
    @discardableResult
    static func quarantineAndRemoveRegularFile(
        _ url: URL,
        expectedIdentity: FileSystemIdentity,
        cleanupPrefix: String,
        ownerPID: pid_t,
        cleanupParent: URL? = nil,
        log: @Sendable (String) -> Void,
        checkpoints: FileRemovalCheckpoints = FileRemovalCheckpoints(),
        stableIdentityOnly: Bool = false
    ) -> Bool {
        let sourceParent = url.deletingLastPathComponent()
        let cleanupDirectory = (cleanupParent ?? sourceParent).appendingPathComponent(
            "\(cleanupPrefix)\(ownerPID)-\(UUID().uuidString)"
        )
        do {
            try OwnedTemporaryDirectory.create(cleanupDirectory, ownerPID: ownerPID)
        } catch {
            log(
                "Cleanup-Verzeichnis konnte nicht angelegt werden: \(cleanupDirectory.path) (\(error.localizedDescription))"
            )
            return false
        }
        guard
            let cleanupIdentity = FileSystemEntry.identity(
                at: cleanupDirectory,
                followSymlink: false
            )
        else { return false }
        let entryRecord = CleanupEntryRecord(
            identity: expectedIdentity,
            filename: "entry",
            stableIdentityOnly: stableIdentityOnly
        )
        do {
            try CleanupEntryRecord.write(
                expectedIdentity,
                in: cleanupDirectory,
                stableIdentityOnly: stableIdentityOnly
            )
        } catch {
            OwnedTemporaryDirectory.remove(
                cleanupDirectory,
                expectedIdentity: cleanupIdentity,
                expectedOwnerPID: ownerPID,
                contents: .recordedOutput(entryRecord)
            )
            log(
                "Cleanup-Identität konnte nicht gesichert werden: \(cleanupDirectory.path) (\(error.localizedDescription))"
            )
            return false
        }
        let quarantined = cleanupDirectory.appendingPathComponent("entry")
        checkpoints.beforeQuarantine?()
        guard
            FileSystemEntry.rename(
                from: url,
                to: quarantined,
                flags: UInt32(RENAME_EXCL)
            ) == 0
        else {
            let number = errno
            OwnedTemporaryDirectory.remove(
                cleanupDirectory,
                expectedIdentity: cleanupIdentity,
                expectedOwnerPID: ownerPID,
                contents: .recordedOutput(entryRecord)
            )
            if number == ENOENT { return true }
            log(
                "Datei konnte nicht quarantänisiert werden: \(url.path) (\(String(cString: strerror(number))))"
            )
            return false
        }
        let movedMatches: Bool
        if case .existing(let moved) = FileSystemEntry.snapshot(of: quarantined) {
            movedMatches =
                stableIdentityOnly
                ? expectedIdentity.matchesRegularFileEntry(moved)
                : expectedIdentity.matchesDisplacedEntry(moved)
        } else {
            movedMatches = false
        }
        guard movedMatches else {
            checkpoints.beforeRestore?()
            let restored =
                FileSystemEntry.rename(
                    from: quarantined,
                    to: url,
                    flags: UInt32(RENAME_EXCL)
                ) == 0
            if restored {
                OwnedTemporaryDirectory.remove(
                    cleanupDirectory,
                    expectedIdentity: cleanupIdentity,
                    expectedOwnerPID: ownerPID,
                    contents: .recordedOutput(entryRecord)
                )
                log("Ausgetauschte Datei bleibt liegen: \(url.path)")
                return false
            }
            if let recoveryURL = preserveRecoveryEntry(
                from: quarantined,
                for: url,
                renameOperation: {
                    FileSystemEntry.rename(from: $0, to: $1, flags: $2)
                }
            ) {
                OwnedTemporaryDirectory.remove(
                    cleanupDirectory,
                    expectedIdentity: cleanupIdentity,
                    expectedOwnerPID: ownerPID,
                    contents: .recordedOutput(entryRecord)
                )
                log(
                    "Ausgetauschte Datei wurde unter einem Recovery-Namen gesichert: \(recoveryURL.path)"
                )
                return false
            }
            let recoveryDirectory = sourceParent.appendingPathComponent(
                "\(OutputArtifactNames.recoveryCleanupPrefix)\(UUID().uuidString)"
            )
            let recoveryDirectoryCreated =
                FileSystemEntry.rename(
                    from: cleanupDirectory,
                    to: recoveryDirectory,
                    flags: UInt32(RENAME_EXCL)
                ) == 0
            if !recoveryDirectoryCreated {
                // Ohne gültige Besitzerdatei nimmt kein automatischer Sweep
                // diesen nicht eindeutig eigenen Eintrag mehr auf.
                let descriptor = FileSystemEntry.openDirectory(cleanupDirectory)
                if descriptor >= 0 {
                    if let bound = FileSystemEntry.identity(of: descriptor),
                        cleanupIdentity.matchesDirectoryEntry(bound)
                    {
                        _ = OwnedTemporaryDirectory.tempOwnerFilename.withCString {
                            Darwin.unlinkat(descriptor, $0, 0)
                        }
                    }
                    _ = Darwin.close(descriptor)
                }
            }
            let remainingPath =
                recoveryDirectoryCreated
                ? recoveryDirectory.path : cleanupDirectory.path
            log(
                "Ausgetauschte Datei bleibt in einem Recovery-Cleanup-Verzeichnis erhalten: \(remainingPath)"
            )
            return false
        }
        checkpoints.afterQuarantine?(cleanupDirectory)
        OwnedTemporaryDirectory.remove(
            cleanupDirectory,
            expectedIdentity: cleanupIdentity,
            expectedOwnerPID: ownerPID,
            contents: .recordedOutput(entryRecord)
        )
        if FileSystemEntry.snapshot(of: cleanupDirectory) != .missing {
            log("Cleanup-Rest bleibt bis zum nächsten Lauf liegen: \(cleanupDirectory.path)")
        }
        // Der geprüfte Eintrag liegt nicht mehr unter seinem produktiven
        // Namen. Ein seltener Cleanup-Rest ist deshalb kein Commit-Fehler.
        return true
    }
}
