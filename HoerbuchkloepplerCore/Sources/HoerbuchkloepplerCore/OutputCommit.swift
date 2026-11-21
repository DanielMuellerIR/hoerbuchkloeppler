import Darwin
import Foundation

enum OutputCommit {
    struct Operations {
        var beforeDestinationCheck: (() -> Void)?
        var rename: (URL, URL, UInt32) -> Int32 = {
            FileSystemEntry.rename(from: $0, to: $1, flags: $2)
        }
        var removeDisplacedOutput: ((URL, FileSystemIdentity) -> Bool)?
    }

    /// Setzt ein zuvor fehlendes Ziel mit `RENAME_EXCL` ein. Ein bestätigtes
    /// vorhandenes Ziel wird atomar mit der Staging-Datei getauscht; erst die
    /// danach tatsächlich verdrängte Datei wird gegen den Bestätigungs-Snapshot
    /// geprüft. Bei Abweichung tauscht die Funktion sofort zurück.
    /// Nach erfolgreicher Übernahme bedeutet `false`, dass Aufräumen der
    /// verdrängten Datei noch aussteht. Der Aufrufer registriert sie zur Wiederholung.
    @discardableResult
    static func publish(
        _ stagedURL: URL,
        to finalURL: URL,
        expectedDestination: OutputDestinationSnapshot,
        expectedDestinationDirectory: OutputDestinationSnapshot? = nil,
        expectedStagingOwnership: StagingOwnership? = nil,
        operations: Operations = Operations()
    ) throws -> Bool {
        guard case .existing(let expectedStagedIdentity) = FileSystemEntry.snapshot(of: stagedURL),
            expectedStagedIdentity.mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            expectedStagedIdentity.size > 0
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard expectedStagingOwnership?.matches(expectedStagedIdentity, at: stagedURL) ?? true
        else {
            throw ConversionOutputError.stagingChanged(stagedURL)
        }
        operations.beforeDestinationCheck?()
        if let expectedDestinationDirectory {
            try ConversionPlanner.validateOutputDirectorySnapshot(
                for: finalURL,
                expected: expectedDestinationDirectory
            )
        }

        switch expectedDestination {
        case .missing:
            guard operations.rename(stagedURL, finalURL, UInt32(RENAME_EXCL)) == 0 else {
                let number = errno
                if number == EEXIST { throw ConversionOutputError.destinationChanged(finalURL) }
                throw POSIXError(POSIXErrorCode(rawValue: number) ?? .EIO)
            }
            guard case .existing(let movedIdentity) = FileSystemEntry.snapshot(of: finalURL),
                expectedStagedIdentity.matchesDisplacedEntry(movedIdentity),
                expectedStagingOwnership?.matches(movedIdentity, at: finalURL) ?? true
            else {
                guard operations.rename(finalURL, stagedURL, UInt32(RENAME_EXCL)) == 0 else {
                    let rollbackError = errno
                    let recoveryURL =
                        OutputCleanup.preserveRecoveryEntry(
                            from: finalURL,
                            for: finalURL,
                            renameOperation: operations.rename
                        ) ?? finalURL
                    throw ConversionOutputError.restoreFailed(
                        finalURL,
                        recoveryURL: recoveryURL,
                        errno: rollbackError
                    )
                }
                throw ConversionOutputError.stagingChanged(stagedURL)
            }
            return true
        case .inaccessible(let number):
            throw ConversionOutputError.destinationInaccessible(finalURL, number)
        case .existing(let expectedIdentity):
            guard
                FileSystemEntry.snapshot(of: finalURL)
                    .matchesContent(of: .existing(expectedIdentity))
            else {
                throw ConversionOutputError.destinationChanged(finalURL)
            }
            guard expectedIdentity.mode & mode_t(S_IFMT) != mode_t(S_IFDIR) else {
                throw ConversionOutputError.destinationIsDirectory(finalURL)
            }
            if let ownership = expectedStagingOwnership,
                let protectedDirectory = ownership.protectedDirectory,
                let protectedIdentity = ownership.protectedDirectoryIdentity
            {
                guard
                    OwnedTemporaryDirectory.matches(
                        protectedDirectory,
                        identity: protectedIdentity,
                        owner: ownership.ownerPID
                    )
                else {
                    throw ConversionOutputError.stagingChanged(stagedURL)
                }
            }
            guard operations.rename(stagedURL, finalURL, UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let movedStagingMatches: Bool
            if case .existing(let movedIdentity) = FileSystemEntry.snapshot(of: finalURL) {
                movedStagingMatches =
                    expectedStagedIdentity
                    .matchesDisplacedEntry(movedIdentity)
                    && (expectedStagingOwnership?.matches(movedIdentity, at: finalURL) ?? true)
            } else {
                movedStagingMatches = false
            }
            let displacedDestinationMatches: Bool
            if case .existing(let displacedIdentity) = FileSystemEntry.snapshot(of: stagedURL) {
                displacedDestinationMatches =
                    expectedIdentity
                    .matchesDisplacedEntry(displacedIdentity)
            } else {
                displacedDestinationMatches = false
            }
            guard movedStagingMatches, displacedDestinationMatches else {
                guard operations.rename(stagedURL, finalURL, UInt32(RENAME_SWAP)) == 0 else {
                    let rollbackError = errno
                    let recoveryURL =
                        OutputCleanup.preserveRecoveryEntry(
                            from: stagedURL,
                            for: finalURL,
                            renameOperation: operations.rename
                        ) ?? stagedURL
                    throw ConversionOutputError.restoreFailed(
                        finalURL,
                        recoveryURL: recoveryURL,
                        errno: rollbackError
                    )
                }
                if !movedStagingMatches {
                    throw ConversionOutputError.stagingChanged(stagedURL)
                }
                throw ConversionOutputError.destinationChanged(finalURL)
            }
            // Erst nach der Prüfung beider Seiten darf ein späterer Lauf die
            // Altdatei entfernen. Stirbt dieser Lauf vorher oder scheitert das
            // Schreiben, schützt der bisherige Staging-Datensatz die Altdatei.
            if let ownership = expectedStagingOwnership,
                let protectedDirectory = ownership.protectedDirectory,
                let protectedIdentity = ownership.protectedDirectoryIdentity,
                OwnedTemporaryDirectory.matches(
                    protectedDirectory,
                    identity: protectedIdentity,
                    owner: ownership.ownerPID
                )
            {
                try? CleanupEntryRecord.write(
                    expectedIdentity,
                    in: protectedDirectory,
                    filename: stagedURL.lastPathComponent
                )
            }
            return operations.removeDisplacedOutput?(stagedURL, expectedIdentity)
                ?? OutputCleanup.removeDisplacedOutput(
                    stagedURL,
                    expectedIdentity: expectedIdentity,
                    cleanupParent: finalURL.deletingLastPathComponent()
                )
        }
    }
}
