import Foundation
import Testing
@testable import HoerbuchkloepplerCore
import Darwin

@Suite("Rückzug und Wiederanlauf der Dateiausgabe")
struct OutputRecoveryTests {
    @Test("Absturz nach dem Zieltausch hinterlässt einen bereinigbaren Staging-Ordner")
    func crashAfterSwapCanSweepDisplacedDestination() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deadOwner: pid_t = 987_654
        let final = directory.appendingPathComponent("Buch.m4b")
        try Data("alt".utf8).write(to: final)
        let expected = FileSystemEntry.snapshot(of: final)
        var staging: StagingOutputHandle? = try OutputStaging.createProtectedOutput(for: final, ownerPID: deadOwner)
        let stagingURL = try #require(staging?.url)
        let ownership = try #require(staging?.ownership)
        let protectedDirectory = try #require(ownership.protectedDirectory)
        try Data("neu".utf8).write(to: stagingURL)

        let removed = try OutputCommit.publish(
            stagingURL,
            to: final,
            expectedDestination: expected,
            expectedStagingOwnership: ownership,
            operations: .init(removeDisplacedOutput: { _, _ in false })
        )
        #expect(!removed)
        #expect(try String(contentsOf: final, encoding: .utf8) == "neu")
        #expect(try String(contentsOf: stagingURL, encoding: .utf8) == "alt")
        staging = nil

        OutputCleanup.removeOrphanedQuarantines(in: directory)

        #expect(!FileManager.default.fileExists(atPath: protectedDirectory.path))
        #expect(try String(contentsOf: final, encoding: .utf8) == "neu")
    }

    @Test("Alter Export bleibt nach fehlgeschlagenem Rücktausch im geschützten Staging erhalten")
    func failedProtectedRollbackRetainsPreviousOutput() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let parked = directory.appendingPathComponent("verschoben.m4b")
        try Data("bestätigtes Ziel".utf8).write(to: final)
        let expected = FileSystemEntry.snapshot(of: final)
        let staging = try OutputStaging.createProtectedOutput(for: final, ownerPID: 987_654)
        try Data("eigene Ausgabe".utf8).write(to: staging.url)
        var swapAttempt = 0

        let error = #expect(throws: ConversionOutputError.self) {
            try OutputCommit.publish(
                staging.url,
                to: final,
                expectedDestination: expected,
                expectedStagingOwnership: staging.ownership,
                operations: .init(rename: { source, destination, flags in
                    guard flags == UInt32(RENAME_SWAP) else {
                        errno = EACCES
                        return -1
                    }
                    swapAttempt += 1
                    let result = FileSystemEntry.rename(from: source, to: destination, flags: flags)
                    if swapAttempt == 1, result == 0 {
                        #expect(
                            FileSystemEntry.rename(
                                from: final, to: parked, flags: UInt32(RENAME_EXCL)) == 0)
                    }
                    return result
                })
            )
        }
        guard case .restoreFailed(let failedTarget, let recovery, let number) = error else {
            Issue.record("Unerwarteter Rücktauschfehler: \(String(describing: error))")
            return
        }
        #expect(failedTarget == final)
        #expect(recovery == staging.url)
        #expect(number == ENOENT)
        #expect(try String(contentsOf: staging.url, encoding: .utf8) == "bestätigtes Ziel")

        OutputCleanup.removeOrphans(for: final)

        #expect(try String(contentsOf: staging.url, encoding: .utf8) == "bestätigtes Ziel")
        #expect(try String(contentsOf: parked, encoding: .utf8) == "eigene Ausgabe")
    }

    @Test("Alter Swap-Datensatz ohne bestätigte Übernahme schützt mögliche Altdatei")
    func oldAlternateCleanupIdentityIsNotDeletionProof() throws {
        struct LegacyRecord: Encodable {
            let identity: FileSystemIdentity
            let filename = "entry.m4b"
            let stableIdentityOnly = true
            let alternateIdentity: FileSystemIdentity
            let alternateStableIdentityOnly = false
        }
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        try Data("bestätigtes Ziel".utf8).write(to: final)
        let original = try #require(FileSystemEntry.identity(at: final, followSymlink: false))
        let staging = try OutputStaging.createProtectedOutput(for: final, ownerPID: 987_654)
        let container = try #require(staging.ownership.protectedDirectory)
        try Data("eigene Ausgabe".utf8).write(to: staging.url)
        try JSONEncoder().encode(
            LegacyRecord(identity: staging.ownership.identity, alternateIdentity: original)
        ).write(to: container.appendingPathComponent(CleanupEntryRecord.markerName))
        let record = try #require(CleanupEntryRecord.read(in: container))
        #expect(record.identity == staging.ownership.identity)
        try FileManager.default.removeItem(at: staging.url)
        try FileManager.default.moveItem(at: final, to: staging.url)

        OutputCleanup.removeOrphans(for: final)

        #expect(try String(contentsOf: staging.url, encoding: .utf8) == "bestätigtes Ziel")
    }

    @Test("Fehlgeschlagenes Staging-Cleanup bleibt bis zum erneuten Versuch registriert")
    func residualProtectedStagingCleanupIsRetried() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staging = try OutputStaging.createProtectedOutput(for: final)
        let protectedDirectory = try #require(
            staging.ownership.protectedDirectory
        )
        try Data("unvollständig".utf8).write(to: staging.url)
        let recovery = protectedDirectory.appendingPathComponent("recovery.txt")
        try Data("behalten".utf8).write(to: recovery)
        let context = ConversionContext()
        context.registerStagedOutput(
            staging.url,
            ownership: staging.ownership
        )

        context.discardStagedOutput(staging.url)

        #expect(FileManager.default.fileExists(atPath: staging.url.path))
        #expect(FileManager.default.fileExists(atPath: recovery.path))
        try FileManager.default.removeItem(at: recovery)
        context.cleanupResidualStagedOutputs()

        #expect(!FileManager.default.fileExists(atPath: protectedDirectory.path))
    }

    @Test("Fehlgeschlagener Container-Cleanup nach Commit wird erneut versucht")
    func committedProtectedContainerCleanupIsRetried() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staging = try OutputStaging.createProtectedOutput(for: final)
        let protectedDirectory = try #require(
            staging.ownership.protectedDirectory
        )
        try Data("fertig".utf8).write(to: staging.url)
        let recovery = protectedDirectory.appendingPathComponent("recovery.txt")
        try Data("behalten".utf8).write(to: recovery)
        let context = ConversionContext()
        context.registerStagedOutput(
            staging.url,
            ownership: staging.ownership
        )
        _ = try OutputCommit.publish(
            staging.url,
            to: final,
            expectedDestination: .missing,
            expectedStagingOwnership: staging.ownership
        )

        context.completeStagedOutput(staging.url)

        #expect(FileManager.default.fileExists(atPath: protectedDirectory.path))
        #expect(FileManager.default.fileExists(atPath: recovery.path))
        try FileManager.default.removeItem(at: recovery)
        context.cleanupResidualStagedOutputs()

        #expect(!FileManager.default.fileExists(atPath: protectedDirectory.path))
        #expect(try String(contentsOf: final, encoding: .utf8) == "fertig")
    }

    @Test("Altdatei-Cleanup liegt neben statt innerhalb des Staging-Ordners")
    func displacedCleanupUsesOutputParent() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staging = try OutputStaging.createProtectedOutput(for: final)
        let protectedDirectory = try #require(
            staging.ownership.protectedDirectory
        )
        try Data("alte Ausgabe".utf8).write(to: staging.url)
        let identity = try #require(
            FileSystemEntry.identity(
                at: staging.url,
                followSymlink: false
            )
        )
        var observedCleanupDirectory: URL?

        _ = OutputCleanup.removeDisplacedOutput(
            staging.url,
            expectedIdentity: identity,
            cleanupParent: directory,
            checkpoints: .init(
                afterQuarantine: { cleanupDirectory in
                    observedCleanupDirectory = cleanupDirectory
                    try? Data("Recovery".utf8).write(
                        to: cleanupDirectory.appendingPathComponent("extra.txt")
                    )
                }
            )
        )

        #expect(
            observedCleanupDirectory?.deletingLastPathComponent()
                .standardizedFileURL.path == directory.standardizedFileURL.path
        )
        let nestedNames = try FileManager.default.contentsOfDirectory(
            atPath: protectedDirectory.path
        )
        #expect(!nestedNames.contains { $0.hasPrefix(".HB_DisplacedCleanup_") })
        #expect(!nestedNames.contains { $0.hasPrefix(".HB_Cleanup_") })
    }

    @Test("Austausch nach der Cleanup-Prüfung löscht den fremden Eintrag nicht")
    func cleanupEntryReplacementAfterCheckIsPreserved() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = ProcessInfo.processInfo.processIdentifier
        let cleanup = directory.appendingPathComponent(
            ".HB_DisplacedCleanup_\(owner)-\(UUID().uuidString)"
        )
        try OwnedTemporaryDirectory.create(cleanup, ownerPID: owner)
        let entry = cleanup.appendingPathComponent("entry")
        try Data("erwartet".utf8).write(to: entry)
        let entryIdentity = try #require(
            FileSystemEntry.identity(at: entry, followSymlink: false)
        )
        try CleanupEntryRecord.write(entryIdentity, in: cleanup)
        let directoryIdentity = try #require(
            FileSystemEntry.identity(at: cleanup, followSymlink: false)
        )
        let record = CleanupEntryRecord(
            identity: entryIdentity,
            filename: "entry",
            stableIdentityOnly: false
        )
        var replacementWritten = false

        OwnedTemporaryDirectory.remove(
            cleanup,
            expectedIdentity: directoryIdentity,
            expectedOwnerPID: owner,
            contents: .recordedOutput(record),
            checkpoints: .init(
                beforeRecordedEntryQuarantine: { descriptor in
                    guard "entry".withCString({
                        Darwin.unlinkat(descriptor, $0, 0)
                    }) == 0 else { return }
                    let replacement = "entry".withCString {
                        Darwin.openat(
                            descriptor,
                            $0,
                            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                            mode_t(0o600)
                        )
                    }
                    guard replacement >= 0 else { return }
                    let payload = Data("fremd".utf8)
                    replacementWritten = payload.withUnsafeBytes {
                        Darwin.write(replacement, $0.baseAddress, $0.count)
                            == $0.count
                    }
                    _ = Darwin.close(replacement)
                }
            )
        )

        #expect(replacementWritten)
        let remains = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".HB_Cleanup_\(owner)-") }
        let remaining = try #require(remains.first)
        #expect(try String(
            contentsOf: remaining.appendingPathComponent("entry"),
            encoding: .utf8
        ) == "fremd")
    }

    @Test("Absturz nach der Entry-Quarantäne bleibt bereinigbar")
    func crashAfterEntryQuarantineIsSwept() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deadOwner: pid_t = 987_654
        let cleanup = directory.appendingPathComponent(
            ".HB_DisplacedCleanup_\(deadOwner)-\(UUID().uuidString)"
        )
        try OwnedTemporaryDirectory.create(
            cleanup,
            ownerPID: deadOwner
        )
        let entry = cleanup.appendingPathComponent("entry")
        try Data("Altdatei".utf8).write(to: entry)
        let identity = try #require(
            FileSystemEntry.identity(at: entry, followSymlink: false)
        )
        try CleanupEntryRecord.write(identity, in: cleanup)
        try FileManager.default.moveItem(
            at: entry,
            to: cleanup.appendingPathComponent(".HB_EntryCleanup")
        )

        OutputCleanup.removeOrphanedQuarantines(in: directory)

        #expect(!FileManager.default.fileExists(atPath: cleanup.path))
    }

    @Test("Verdrängte Altdatei und geschützter Ordner werden gemeinsam nachbereinigt")
    func protectedDisplacedOutputRetainsContainerUntilRetry() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        try Data("alt".utf8).write(to: final)
        let expected = FileSystemEntry.snapshot(of: final)
        let staging = try OutputStaging.createProtectedOutput(for: final)
        try Data("neu".utf8).write(to: staging.url)
        let context = ConversionContext()
        context.registerStagedOutput(
            staging.url,
            ownership: staging.ownership
        )

        let removed = try OutputCommit.publish(
            staging.url,
            to: final,
            expectedDestination: expected,
            expectedStagingOwnership: staging.ownership,
            operations: .init(removeDisplacedOutput: { _, _ in false })
        )
        #expect(!removed)
        guard case .existing(let oldIdentity) = expected else {
            Issue.record("Bestehendes Ziel lieferte keinen Snapshot")
            return
        }
        context.registerDisplacedOutput(
            staging.url,
            expectedIdentity: oldIdentity
        )
        let protectedDirectory = try #require(
            staging.ownership.protectedDirectory
        )
        #expect(FileManager.default.fileExists(atPath: protectedDirectory.path))

        context.cleanupResidualStagedOutputs()

        #expect(!FileManager.default.fileExists(atPath: protectedDirectory.path))
        #expect(try String(contentsOf: final, encoding: .utf8) == "neu")
    }

    @Test("Abbruch registriert fehlgeschlagenes Altdatei-Cleanup erneut")
    func cancellationRetriesDisplacedOutputCleanup() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        try Data("alt".utf8).write(to: final)
        let expected = FileSystemEntry.snapshot(of: final)
        guard case .existing(let oldIdentity) = expected else {
            Issue.record("Bestehendes Ziel lieferte keinen Snapshot")
            return
        }
        let staging = try OutputStaging.createProtectedOutput(for: final)
        let protectedDirectory = try #require(
            staging.ownership.protectedDirectory
        )
        try Data("neu".utf8).write(to: staging.url)
        let context = ConversionContext { _, _ in
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: protectedDirectory.path
            )
        }
        context.registerStagedOutput(
            staging.url,
            ownership: staging.ownership
        )
        _ = try OutputCommit.publish(
            staging.url,
            to: final,
            expectedDestination: expected,
            expectedStagingOwnership: staging.ownership,
            operations: .init(removeDisplacedOutput: { _, _ in false })
        )
        context.registerDisplacedOutput(
            staging.url,
            expectedIdentity: oldIdentity,
            stagingOwnership: staging.ownership
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: protectedDirectory.path
        )

        #expect(context.cancel())
        context.finishAfterCancellationCleanup { _ in }
        context.cleanupResidualStagedOutputs()

        #expect(!FileManager.default.fileExists(atPath: protectedDirectory.path))
        #expect(try String(contentsOf: final, encoding: .utf8) == "neu")
    }

    @Test("Rollback-Fehler rettet die verdrängte Datei außerhalb der Altlastenbereinigung")
    func failedRollbackUsesRecoveryName() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = OutputArtifactNames.stagingOutputURL(for: final)
        let replacement = directory.appendingPathComponent("fremd.m4b")
        try Data("bestätigtes Ziel".utf8).write(to: final)
        try Data("eigene Ausgabe".utf8).write(to: staged)
        try Data("fremder Ersatz".utf8).write(to: replacement)
        let expected = FileSystemEntry.snapshot(of: final)
        var renameCount = 0
        var recoveryURL: URL?

        do {
            _ = try OutputCommit.publish(
                staged,
                to: final,
                expectedDestination: expected,
                operations: .init(
                    beforeDestinationCheck: {
                        try? FileManager.default.removeItem(at: staged)
                        try? FileManager.default.moveItem(at: replacement, to: staged)
                    },
                    rename: { source, destination, flags in
                        renameCount += 1
                        if renameCount == 2 {
                            errno = EIO
                            return -1
                        }
                        return FileSystemEntry.rename(
                            from: source,
                            to: destination,
                            flags: flags
                        )
                    }
                )
            )
            Issue.record("Erzwungener Rollback-Fehler blieb aus")
        } catch let error as ConversionOutputError {
            guard case .restoreFailed(_, let recovered, _) = error else {
                Issue.record("Unerwarteter Ausgabefehler: \(error)")
                return
            }
            recoveryURL = recovered
        }

        let recovered = try #require(recoveryURL)
        #expect(!recovered.lastPathComponent.contains(".partial-"))
        #expect(try String(contentsOf: final, encoding: .utf8) == "fremder Ersatz")
        #expect(try String(contentsOf: recovered, encoding: .utf8) == "bestätigtes Ziel")
        OutputCleanup.removeOrphans(for: final)
        #expect(FileManager.default.fileExists(atPath: recovered.path))
    }

    @Test("Auch ohne möglichen Recovery-Rename bleibt das alte Ziel geschützt")
    func failedRecoveryRenameRemainsProtectedFromOrphanCleanup() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = OutputArtifactNames.stagingOutputURL(for: final, ownerPID: 987_654)
        let replacement = directory.appendingPathComponent("fremd.m4b")
        try Data("bestätigtes Ziel".utf8).write(to: final)
        try Data("eigene Ausgabe".utf8).write(to: staged)
        try Data("fremder Ersatz".utf8).write(to: replacement)
        let expected = FileSystemEntry.snapshot(of: final)
        var renameCount = 0
        var reportedRecovery: URL?

        do {
            _ = try OutputCommit.publish(
                staged,
                to: final,
                expectedDestination: expected,
                operations: .init(
                    beforeDestinationCheck: {
                        try? FileManager.default.removeItem(at: staged)
                        try? FileManager.default.moveItem(at: replacement, to: staged)
                    },
                    rename: { source, destination, flags in
                        renameCount += 1
                        if renameCount >= 2 {
                            errno = EIO
                            return -1
                        }
                        return FileSystemEntry.rename(
                            from: source,
                            to: destination,
                            flags: flags
                        )
                    }
                )
            )
        } catch let error as ConversionOutputError {
            guard case .restoreFailed(_, let recovery, _) = error else {
                Issue.record("Unerwarteter Fehler: \(error)")
                return
            }
            reportedRecovery = recovery
        }

        #expect(reportedRecovery == staged)
        OutputCleanup.removeOrphans(for: final)
        #expect(try String(contentsOf: staged, encoding: .utf8) == "bestätigtes Ziel")
    }

    @Test("Fehlgeschlagener Altdatei-Unlink bleibt registriert und wird erneut versucht")
    func displacedOutputCleanupIsRetried() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = directory.appendingPathComponent(".staged.m4b")
        try Data("alt".utf8).write(to: final)
        try Data("neu".utf8).write(to: staged)
        let expected = FileSystemEntry.snapshot(of: final)
        let context = ConversionContext()
        context.registerStagedOutput(staged)

        let removed = try OutputCommit.publish(
            staged,
            to: final,
            expectedDestination: expected,
            operations: .init(removeDisplacedOutput: { _, _ in false })
        )

        #expect(!removed)
        #expect(try String(contentsOf: final, encoding: .utf8) == "neu")
        #expect(try String(contentsOf: staged, encoding: .utf8) == "alt")
        guard case .existing(let displacedIdentity) = expected else {
            Issue.record("Bestehendes Ziel lieferte keinen Snapshot")
            return
        }
        context.registerDisplacedOutput(
            staged,
            expectedIdentity: displacedIdentity
        )
        context.cleanupResidualStagedOutputs()
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test("Bereinigung einer verdrängten Ausgabe löscht keinen späten Ersatz")
    func displacedOutputCleanupRechecksQuarantine() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let displaced = directory.appendingPathComponent(".partial.m4b")
        let parked = directory.appendingPathComponent("alt-gesichert.m4b")
        let replacement = directory.appendingPathComponent("fremd.m4b")
        try Data("bestätigte Altdatei".utf8).write(to: displaced)
        try Data("fremder Ersatz".utf8).write(to: replacement)
        let identity = try #require(
            FileSystemEntry.identity(at: displaced, followSymlink: false)
        )
        var hookError: (any Error)?

        let removed = OutputCleanup.removeDisplacedOutput(
            displaced,
            expectedIdentity: identity,
            checkpoints: .init(
                beforeQuarantine: {
                    do {
                        try FileManager.default.moveItem(at: displaced, to: parked)
                        try FileManager.default.moveItem(at: replacement, to: displaced)
                    } catch {
                        hookError = error
                    }
                }
            )
        )

        #expect(hookError == nil)
        #expect(!removed)
        #expect(try String(contentsOf: displaced, encoding: .utf8) == "fremder Ersatz")
        #expect(try String(contentsOf: parked, encoding: .utf8) == "bestätigte Altdatei")
    }

    @Test("Ein Ersatz am Cleanup-Pfad wird bei verdrängten Ausgaben nicht gelöscht")
    func displacedCleanupIsBoundToOwnedDirectory() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let displaced = directory.appendingPathComponent("alt.m4b")
        let parked = directory.appendingPathComponent("cleanup-gesichert")
        try Data("bestätigte Altdatei".utf8).write(to: displaced)
        let identity = try #require(
            FileSystemEntry.identity(at: displaced, followSymlink: false)
        )
        var replacementPayload: URL?
        var hookError: (any Error)?

        let removed = OutputCleanup.removeDisplacedOutput(
            displaced,
            expectedIdentity: identity,
            checkpoints: .init(
                afterQuarantine: { cleanupDirectory in
                    do {
                        try FileManager.default.moveItem(
                            at: cleanupDirectory,
                            to: parked
                        )
                        try FileManager.default.createDirectory(
                            at: cleanupDirectory,
                            withIntermediateDirectories: false
                        )
                        let payload = cleanupDirectory.appendingPathComponent("wichtig.txt")
                        try Data("nicht anfassen".utf8).write(to: payload)
                        replacementPayload = payload
                    } catch {
                        hookError = error
                    }
                }
            )
        )

        #expect(removed)
        #expect(hookError == nil)
        #expect(FileManager.default.fileExists(atPath: try #require(replacementPayload).path))
        #expect(FileManager.default.fileExists(atPath: parked.appendingPathComponent("entry").path))
    }

    @Test("Eine nach der Vorprüfung eingeschleuste Datei rettet den Cleanup-Ordner")
    func cleanupKeepsDirectoryWhenForeignFileAppearsAfterScan() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = ProcessInfo.processInfo.processIdentifier
        let cleanup = directory.appendingPathComponent(
            ".HB_DisplacedCleanup_\(owner)-\(UUID().uuidString)"
        )
        try OwnedTemporaryDirectory.create(cleanup, ownerPID: owner)
        let entry = cleanup.appendingPathComponent("entry")
        try Data("erwartet".utf8).write(to: entry)
        let entryIdentity = try #require(
            FileSystemEntry.identity(at: entry, followSymlink: false)
        )
        try CleanupEntryRecord.write(entryIdentity, in: cleanup)
        let directoryIdentity = try #require(
            FileSystemEntry.identity(at: cleanup, followSymlink: false)
        )
        let record = CleanupEntryRecord(
            identity: entryIdentity,
            filename: "entry",
            stableIdentityOnly: false
        )
        var intruderWritten = false

        OwnedTemporaryDirectory.remove(
            cleanup,
            expectedIdentity: directoryIdentity,
            expectedOwnerPID: owner,
            contents: .recordedOutput(record),
            checkpoints: .init(
                beforeRecordedEntryQuarantine: { descriptor in
                    // Der aufgezeichnete Eintrag bleibt unangetastet; dazu kommt
                    // eine Datei, die es beim ersten Namens-Scan noch nicht gab.
                    let intruder = "fremd.txt".withCString {
                        Darwin.openat(
                            descriptor,
                            $0,
                            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                            mode_t(0o600)
                        )
                    }
                    guard intruder >= 0 else { return }
                    let payload = Data("Recovery-Daten".utf8)
                    intruderWritten = payload.withUnsafeBytes {
                        Darwin.write(intruder, $0.baseAddress, $0.count) == $0.count
                    }
                    _ = Darwin.close(intruder)
                }
            )
        )

        #expect(intruderWritten)
        let remains = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".HB_Cleanup_\(owner)-") }
        let remaining = try #require(remains.first)
        #expect(try String(
            contentsOf: remaining.appendingPathComponent("fremd.txt"),
            encoding: .utf8
        ) == "Recovery-Daten")
        // Ohne Besitzerdatei könnte kein späterer Lauf diesen Rest je wieder
        // als eigenen erkennen — sie muss deshalb liegen bleiben.
        #expect(FileManager.default.fileExists(
            atPath: remaining.appendingPathComponent(".owner-pid").path
        ))
    }

    @Test("Ein Ersatz innerhalb des Cleanup-Ordners bleibt erhalten")
    func cleanupRechecksEntryThroughBoundDirectory() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let displaced = directory.appendingPathComponent("alt.m4b")
        let parked = directory.appendingPathComponent("bestätigt-gesichert.m4b")
        try Data("bestätigte Altdatei".utf8).write(to: displaced)
        let identity = try #require(
            FileSystemEntry.identity(at: displaced, followSymlink: false)
        )
        var insertedEntry: URL?
        var hookError: (any Error)?

        let removed = OutputCleanup.removeDisplacedOutput(
            displaced,
            expectedIdentity: identity,
            checkpoints: .init(
                afterQuarantine: { cleanupDirectory in
                    do {
                        let entry = cleanupDirectory.appendingPathComponent("entry")
                        try FileManager.default.moveItem(at: entry, to: parked)
                        try Data("fremder Ersatz".utf8).write(to: entry)
                        insertedEntry = entry
                    } catch {
                        hookError = error
                    }
                }
            )
        )

        #expect(removed)
        #expect(hookError == nil)
        #expect(try String(contentsOf: parked, encoding: .utf8) == "bestätigte Altdatei")
        let cleanupRests = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".HB_Cleanup_") }
        #expect(cleanupRests.count == 1)
        let preserved = try #require(cleanupRests.first)
            .appendingPathComponent(try #require(insertedEntry).lastPathComponent)
        #expect(try String(contentsOf: preserved, encoding: .utf8) == "fremder Ersatz")
    }

    @Test("Fehlgeschlagener Cleanup-Rollback rettet beide fremden Dateien")
    func failedCleanupRestoreUsesRecoveryName() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("alt.m4b")
        let expectedParked = directory.appendingPathComponent("erwartet-gesichert.m4b")
        let firstReplacement = directory.appendingPathComponent("fremd-eins.m4b")
        try Data("erwartete Datei".utf8).write(to: source)
        let expected = try #require(
            FileSystemEntry.identity(at: source, followSymlink: false)
        )
        try Data("fremd eins".utf8).write(to: firstReplacement)
        var hookError: (any Error)?

        let removed = OutputCleanup.removeDisplacedOutput(
            source,
            expectedIdentity: expected,
            checkpoints: .init(
                beforeQuarantine: {
                    do {
                        try FileManager.default.moveItem(at: source, to: expectedParked)
                        try FileManager.default.moveItem(at: firstReplacement, to: source)
                    } catch {
                        hookError = error
                    }
                },
                beforeRestore: {
                    do {
                        try Data("fremd zwei".utf8).write(to: source)
                    } catch {
                        hookError = error
                    }
                }
            )
        )

        #expect(!removed)
        #expect(hookError == nil)
        #expect(try String(contentsOf: source, encoding: .utf8) == "fremd zwei")
        #expect(try String(contentsOf: expectedParked, encoding: .utf8) == "erwartete Datei")
        let recoveryFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".recovery-") }
        #expect(recoveryFiles.count == 1)
        #expect(try String(contentsOf: try #require(recoveryFiles.first), encoding: .utf8) == "fremd eins")
    }

    @Test("Ein Ersatz am Cleanup-Pfad wird bei Staging-Ausgaben nicht gelöscht")
    func stagingCleanupIsBoundToOwnedDirectory() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = OutputArtifactNames.stagingOutputURL(
            for: directory.appendingPathComponent("Buch.m4b")
        )
        let parked = directory.appendingPathComponent("cleanup-gesichert")
        let ownership = try OutputStaging.createLegacyOutput(staged)
        try Data("unvollständig".utf8).write(to: staged)
        var replacementPayload: URL?
        var hookError: (any Error)?

        let removed = OutputCleanup.removeLegacyOutput(
            staged,
            expectedOwnership: ownership,
            checkpoints: .init(
                afterQuarantine: { cleanupDirectory in
                    do {
                        try FileManager.default.moveItem(
                            at: cleanupDirectory,
                            to: parked
                        )
                        try FileManager.default.createDirectory(
                            at: cleanupDirectory,
                            withIntermediateDirectories: false
                        )
                        let payload = cleanupDirectory.appendingPathComponent("wichtig.txt")
                        try Data("nicht anfassen".utf8).write(to: payload)
                        replacementPayload = payload
                    } catch {
                        hookError = error
                    }
                }
            )
        )

        #expect(removed)
        #expect(hookError == nil)
        #expect(FileManager.default.fileExists(atPath: try #require(replacementPayload).path))
        #expect(FileManager.default.fileExists(atPath: parked.appendingPathComponent("entry").path))
    }

    @Test("Verwaiste Ausgabe-Cleanup-Verzeichnisse werden nach einem Absturz entfernt")
    func orphanedOutputCleanupDirectoriesAreSwept() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deadOwner: pid_t = 987_654
        let stagingCleanup = directory.appendingPathComponent(
            ".HB_StagingCleanup_\(deadOwner)-\(UUID().uuidString)"
        )
        let displacedCleanup = directory.appendingPathComponent(
            ".HB_DisplacedCleanup_\(deadOwner)-\(UUID().uuidString)"
        )
        let reboundCleanup = directory.appendingPathComponent(
            ".HB_Cleanup_\(deadOwner)-\(UUID().uuidString)"
        )
        for cleanup in [stagingCleanup, displacedCleanup, reboundCleanup] {
            try OwnedTemporaryDirectory.create(
                cleanup,
                ownerPID: deadOwner
            )
            let entry = cleanup.appendingPathComponent("entry")
            try Data("Rest".utf8).write(to: entry)
            let identity = try #require(
                FileSystemEntry.identity(
                    at: entry,
                    followSymlink: false
                )
            )
            try CleanupEntryRecord.write(
                identity,
                in: cleanup
            )
        }

        OutputCleanup.removeOrphanedQuarantines(in: directory)

        #expect(!FileManager.default.fileExists(atPath: stagingCleanup.path))
        #expect(!FileManager.default.fileExists(atPath: displacedCleanup.path))
        #expect(!FileManager.default.fileExists(atPath: reboundCleanup.path))
    }

    @Test("Absturz-Sweep erhält einen fremden Eintrag in der Cleanup-Quarantäne")
    func outputCleanupSweepRejectsMismatchedEntry() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deadOwner: pid_t = 987_654
        let cleanup = directory.appendingPathComponent(
            ".HB_DisplacedCleanup_\(deadOwner)-\(UUID().uuidString)"
        )
        try OwnedTemporaryDirectory.create(cleanup, ownerPID: deadOwner)
        let expectedSource = directory.appendingPathComponent("erwartet.m4b")
        try Data("erwartet".utf8).write(to: expectedSource)
        let expected = try #require(
            FileSystemEntry.identity(
                at: expectedSource,
                followSymlink: false
            )
        )
        try CleanupEntryRecord.write(expected, in: cleanup)
        let entry = cleanup.appendingPathComponent("entry")
        try Data("fremder Eintrag".utf8).write(to: entry)

        OutputCleanup.removeOrphanedQuarantines(in: directory)

        #expect(FileManager.default.fileExists(atPath: cleanup.path))
        #expect(try String(contentsOf: entry, encoding: .utf8) == "fremder Eintrag")
    }
}

@Suite("Staging-Bereinigung nach Abbruch")
@MainActor
struct CancelledOutputCleanupTests {
    @Test("discardStagedOutput löscht einen untergeschobenen Ordner nicht rekursiv")
    func discardStagedOutputDoesNotDeleteDirectories() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = directory.appendingPathComponent(".Buch.partial-1234.m4b")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let inhalt = staging.appendingPathComponent("wichtig.txt")
        try Data("nicht löschen".utf8).write(to: inhalt)

        let logs = ThreadSafeLogProbe()
        let context = ConversionContext { _, message in logs.append(message) }
        context.registerStagedOutput(staging)
        context.discardStagedOutput(staging)

        #expect(FileManager.default.fileExists(atPath: inhalt.path))
        #expect(logs.snapshot().contains { $0.contains("Besitzer-Markierung") })
    }

    @Test("cancel löscht einen untergeschobenen Ordner nicht rekursiv")
    func cancelDoesNotDeleteDirectories() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = directory.appendingPathComponent(".Buch.partial-5678.m4b")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let inhalt = staging.appendingPathComponent("wichtig.txt")
        try Data("nicht löschen".utf8).write(to: inhalt)

        let context = ConversionContext()
        context.registerStagedOutput(staging)
        context.cancel()
        // Ohne diese Barriere prüfte der Test, bevor die Bereinigung überhaupt
        // gelaufen war: Seit sie im Hintergrund läuft, gewänne der Testthread
        // das Rennen fast immer und ein rekursives Löschen bliebe unbemerkt.
        #expect(context.waitForCancellationCleanup())

        #expect(FileManager.default.fileExists(atPath: inhalt.path))
    }

    /// Nach einem gewonnenen Abbruch besitzt nur noch die Abbruchbereinigung
    /// die Staging-Einträge samt ihrer Ownership. Läuft der Worker danach in
    /// seinen Fehlerpfad, darf sein `discardStagedOutput` denselben Eintrag
    /// weder anfassen noch als liegengeblieben melden — sonst behauptet die
    /// Meldung eine oft mehrere Gigabyte große Leiche, die es nicht gibt.
    @Test("Der Worker meldet nach gewonnenem Abbruch keine liegengebliebene Datei")
    func discardAfterWonCancellationStaysSilent() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let logs = ThreadSafeLogProbe()
        let context = ConversionContext { _, message in logs.append(message) }
        #expect(context.cancel())

        // Genau der Eintrag, den die Abbruchbereinigung gleich entfernt: Er
        // liegt noch da, der Worker hat seine Ownership aber schon verloren.
        let staging = directory.appendingPathComponent("entry.m4b")
        try Data("teilweise geschrieben".utf8).write(to: staging)
        context.discardStagedOutput(staging)

        #expect(logs.snapshot().isEmpty)
        #expect(FileManager.default.fileExists(atPath: staging.path))
    }
}
