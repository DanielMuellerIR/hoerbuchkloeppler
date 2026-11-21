import Darwin
import Foundation

/// Laufzeitnachweis für die exklusiv angelegte Staging-Datei. Bei älteren
/// Partial-Dateien ist das xattr auch der Besitznachweis nach einem Absturz.
/// Geschützte Arbeitsordner hinterlegen ihre Identität zusätzlich als Datensatz.
struct StagingOwnership: Sendable {
    let identity: FileSystemIdentity
    let ownerPID: pid_t
    let hasPersistentMarker: Bool
    let protectedDirectory: URL?
    let protectedDirectoryIdentity: FileSystemIdentity?

    func matches(_ current: FileSystemIdentity, at url: URL) -> Bool {
        identity.matchesRegularFileEntry(current)
            && (!hasPersistentMarker
                || OutputStaging.hasOwnerMarker(url, expectedOwnerPID: ownerPID))
    }

    var cleanupEntryRecord: CleanupEntryRecord {
        CleanupEntryRecord(
            identity: identity,
            filename: protectedDirectory == nil ? "entry" : "entry.m4b",
            stableIdentityOnly: true
        )
    }
}

final class StagingOutputHandle: Sendable {
    let url: URL
    let ownership: StagingOwnership
    private let descriptor: Int32

    init(url: URL, ownership: StagingOwnership, descriptor: Int32) {
        self.url = url
        self.ownership = ownership
        self.descriptor = descriptor
    }

    deinit {
        _ = Darwin.close(descriptor)
    }

    func stillOwnsProtectedOutput() -> Bool {
        guard let current = FileSystemEntry.identity(at: url, followSymlink: false),
            ownership.matches(current, at: url),
            let directory = ownership.protectedDirectory,
            let identity = ownership.protectedDirectoryIdentity
        else { return false }
        return OwnedTemporaryDirectory.matches(
            directory, identity: identity, owner: ownership.ownerPID)
    }

    /// Foundation reicht den offenen Deskriptor als stdin (FD 0) an FFmpeg weiter.
    /// FFmpeg öffnet /dev/fd/0 als Ausgabe und liest dank -nostdin keine Befehle.
    func processInputHandle() -> FileHandle {
        FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    }
}

enum OutputStaging {
    private static let stagingOwnerAttribute = "com.hoerbuchkloeppler.staging-owner"

    /// Älteres Staging-Format mit einem PID-Marker am exklusiv angelegten Inode.
    @discardableResult
    static func createLegacyOutput(
        _ url: URL,
        ownerPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        setOwnershipMarker: (Int32, String) -> Int32 = setStagingOwnershipMarker
    ) throws -> StagingOwnership {
        let creation = try openNewOutput(
            url,
            ownerPID: ownerPID,
            setOwnershipMarker: setOwnershipMarker
        )
        _ = Darwin.close(creation.descriptor)
        return creation.ownership
    }

    private static func setStagingOwnershipMarker(
        _ descriptor: Int32,
        _ owner: String
    ) -> Int32 {
        owner.withCString { value in
            stagingOwnerAttribute.withCString { name in
                Darwin.fsetxattr(
                    descriptor,
                    name,
                    value,
                    strlen(value),
                    0,
                    XATTR_CREATE
                )
            }
        }
    }

    private static func openNewOutput(
        _ url: URL,
        ownerPID: pid_t,
        setOwnershipMarker: (Int32, String) -> Int32
    ) throws -> (ownership: StagingOwnership, descriptor: Int32) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return Darwin.open(
                path,
                O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o644)
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var createdInformation = stat()
        guard Darwin.fstat(descriptor, &createdInformation) == 0 else {
            let number = errno
            _ = Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: number) ?? .EIO)
        }
        let createdIdentity = FileSystemIdentity(stat: createdInformation)
        guard Darwin.fchmod(descriptor, mode_t(0o644)) == 0 else {
            let number = errno
            _ = Darwin.close(descriptor)
            _ = OutputCleanup.quarantineAndRemoveRegularFile(
                url,
                expectedIdentity: createdIdentity,
                cleanupPrefix: OutputArtifactNames.stagingCleanupPrefix,
                ownerPID: ownerPID,
                log: { _ in },
                stableIdentityOnly: true
            )
            throw POSIXError(POSIXErrorCode(rawValue: number) ?? .EIO)
        }
        let markerResult = setOwnershipMarker(descriptor, String(ownerPID))
        let markerError = errno
        var information = stat()
        let identityResult = Darwin.fstat(descriptor, &information)
        let identityError = errno
        let markerUnsupported =
            markerResult != 0
            && (markerError == ENOTSUP || markerError == EOPNOTSUPP)
        guard markerResult == 0 || markerUnsupported,
            identityResult == 0
        else {
            _ = Darwin.close(descriptor)
            _ = OutputCleanup.quarantineAndRemoveRegularFile(
                url,
                expectedIdentity: createdIdentity,
                cleanupPrefix: OutputArtifactNames.stagingCleanupPrefix,
                ownerPID: ownerPID,
                log: { _ in },
                stableIdentityOnly: true
            )
            let number = identityResult == 0 ? markerError : identityError
            throw POSIXError(POSIXErrorCode(rawValue: number) ?? .EIO)
        }
        return (
            StagingOwnership(
                identity: FileSystemIdentity(stat: information),
                ownerPID: ownerPID,
                hasPersistentMarker: markerResult == 0,
                protectedDirectory: nil,
                protectedDirectoryIdentity: nil
            ),
            descriptor
        )
    }

    static func currentOwnership(at url: URL) -> StagingOwnership? {
        guard let identity = FileSystemEntry.identity(at: url, followSymlink: false)
        else { return nil }
        let owner =
            OutputArtifactNames.stagedOutputOwnerPID(url)
            ?? ProcessInfo.processInfo.processIdentifier
        return StagingOwnership(
            identity: identity,
            ownerPID: owner,
            hasPersistentMarker: hasOwnerMarker(
                url,
                expectedOwnerPID: owner
            ),
            protectedDirectory: nil,
            protectedDirectoryIdentity: nil
        )
    }

    /// Legt den Arbeitsordner auf dem Zielvolume an. FFmpeg schreibt über
    /// den festgehaltenen Dateideskriptor, auch wenn sich der Pfad später ändert.
    static func createProtectedOutput(
        for finalURL: URL,
        ownerPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) throws -> StagingOutputHandle {
        let directory = finalURL.deletingLastPathComponent().appendingPathComponent(
            "\(OutputArtifactNames.workDirectoryPrefix)\(ownerPID)-\(UUID().uuidString)"
        )
        try OwnedTemporaryDirectory.create(directory, ownerPID: ownerPID)
        guard
            let directoryIdentity = FileSystemEntry.identity(
                at: directory,
                followSymlink: false
            )
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = directory.appendingPathComponent("entry.m4b")
        var expectedEntry: CleanupEntryRecord?
        var retainedDescriptor: Int32?
        do {
            let created = try openNewOutput(
                url,
                ownerPID: ownerPID,
                setOwnershipMarker: setStagingOwnershipMarker
            )
            retainedDescriptor = created.descriptor
            let ownership = StagingOwnership(
                identity: created.ownership.identity,
                ownerPID: ownerPID,
                hasPersistentMarker: created.ownership.hasPersistentMarker,
                protectedDirectory: directory,
                protectedDirectoryIdentity: directoryIdentity
            )
            expectedEntry = ownership.cleanupEntryRecord
            try CleanupEntryRecord.write(
                ownership.identity,
                in: directory,
                filename: url.lastPathComponent,
                stableIdentityOnly: true
            )
            return StagingOutputHandle(
                url: url,
                ownership: ownership,
                descriptor: created.descriptor
            )
        } catch {
            if let retainedDescriptor {
                _ = Darwin.close(retainedDescriptor)
            }
            OwnedTemporaryDirectory.remove(
                directory,
                expectedIdentity: directoryIdentity,
                expectedOwnerPID: ownerPID,
                contents: expectedEntry.map(OwnedTemporaryDirectory.Contents.recordedOutput)
                    ?? .emptyStaging
            )
            throw error
        }
    }

    static func hasOwnerMarker(
        _ url: URL,
        expectedOwnerPID: pid_t
    ) -> Bool {
        var bytes = [CChar](repeating: 0, count: 32)
        let count = url.withUnsafeFileSystemRepresentation { path -> Int in
            guard let path else { return -1 }
            return stagingOwnerAttribute.withCString { name in
                Darwin.getxattr(
                    path,
                    name,
                    &bytes,
                    bytes.count - 1,
                    0,
                    XATTR_NOFOLLOW
                )
            }
        }
        guard count > 0, count < bytes.count else { return false }
        return String(decoding: bytes.prefix(count).map(UInt8.init), as: UTF8.self)
            == String(expectedOwnerPID)
    }

    static func clearOwnerMarker(_ url: URL) {
        _ = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return stagingOwnerAttribute.withCString { name in
                Darwin.removexattr(path, name, XATTR_NOFOLLOW)
            }
        }
    }
}
