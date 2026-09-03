import Foundation
import Darwin

// Dateisystem-Sicherheitsgrenze der Ausgabe: Ein Eintrag wird über Gerät und
// Inode wiedererkannt, exklusiv angelegt, gegen prozessübergreifende Sperren
// abgesichert, atomar ins Ziel getauscht und nur dann bereinigt, wenn er
// nachweislich der eigene ist. Alles hier hält genau diese Zusage; die
// Kodierpipeline ruft es nur auf.

/// Dateiname der Besitzermarke in jedem exklusiv angelegten Arbeitsordner.
private let tempOwnerFilename = ".owner-pid"
/// Aufgezeichnete Identität des einen Eintrags, den ein Cleanup-Ordner
/// entfernen darf.
private let cleanupEntryIdentityFilename = ".entry-identity.json"
/// Extended Attribute, das die Besitzer-PID am Inode der Staging-Datei hält.
private let stagingOwnerAttribute = "com.hoerbuchkloeppler.staging-owner"
/// Prozessinterne Belegung der Ausgabeziele. Die dateibasierte `fcntl`-Sperre
/// wirkt zwischen Prozessen; innerhalb eines Prozesses meldet dieses Register
/// ein zweites Fenster auf dasselbe Ziel ab.
private let outputLeaseRegistryLock = NSLock()
private nonisolated(unsafe) var leasedOutputPaths = Set<String>()

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

    /// Ein atomarer Rename aktualisiert auf manchen Volumes die Statuszeit des
    /// verschobenen Eintrags. Für die Prüfung NACH `RENAME_SWAP` zählen deshalb
    /// Inode, Volume, Typ, Größe und Inhalts-Änderungszeit; die strengere
    /// Vorprüfung vergleicht weiterhin alle Felder über `Equatable`.
    func matchesDisplacedEntry(_ other: FileSystemIdentity) -> Bool {
        device == other.device
            && inode == other.inode
            && mode == other.mode
            && size == other.size
            && modificationSeconds == other.modificationSeconds
            && modificationNanoseconds == other.modificationNanoseconds
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

/// Laufzeitnachweis für genau die exklusiv angelegte Staging-Datei. Auf
/// Volumes ohne Extended Attributes bleibt der Inode-Nachweis nutzbar; nur eine
/// spätere Altlastenbereinigung nach einem Prozessabsturz entfällt dort.
struct StagingOwnership: Sendable {
    let identity: FileSystemIdentity
    let ownerPID: pid_t
    let hasPersistentMarker: Bool
    let protectedDirectory: URL?
    let protectedDirectoryIdentity: FileSystemIdentity?

    var cleanupEntryRecord: CleanupEntryRecord {
        CleanupEntryRecord(
            identity: identity,
            filename: protectedDirectory == nil ? "entry" : "entry.m4b",
            stableIdentityOnly: true
        )
    }
}

struct CleanupEntryRecord: Codable {
    let identity: FileSystemIdentity
    let filename: String
    let stableIdentityOnly: Bool
    let alternateIdentity: FileSystemIdentity?
    let alternateStableIdentityOnly: Bool?

    init(
        identity: FileSystemIdentity,
        filename: String,
        stableIdentityOnly: Bool,
        alternateIdentity: FileSystemIdentity? = nil,
        alternateStableIdentityOnly: Bool? = nil
    ) {
        self.identity = identity
        self.filename = filename
        self.stableIdentityOnly = stableIdentityOnly
        self.alternateIdentity = alternateIdentity
        self.alternateStableIdentityOnly = alternateStableIdentityOnly
    }

    func matches(_ current: FileSystemIdentity) -> Bool {
        let primaryMatches = stableIdentityOnly
            ? identity.matchesRegularFileEntry(current)
            : identity.matchesDisplacedEntry(current)
        guard !primaryMatches, let alternateIdentity else {
            return primaryMatches
        }
        return alternateStableIdentityOnly == true
            ? alternateIdentity.matchesRegularFileEntry(current)
            : alternateIdentity.matchesDisplacedEntry(current)
    }
}

final class StagingOutputHandle: @unchecked Sendable {
    let url: URL
    let ownership: StagingOwnership
    let descriptor: Int32

    init(url: URL, ownership: StagingOwnership, descriptor: Int32) {
        self.url = url
        self.ownership = ownership
        self.descriptor = descriptor
    }

    deinit {
        _ = Darwin.close(descriptor)
    }

    func processInputHandle() -> FileHandle {
        FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    }
}

enum OutputDestinationSnapshot: Equatable, Sendable {
    case missing
    case existing(FileSystemIdentity)
    case inaccessible(errno: Int32)
}

enum ConversionOutputError: LocalizedError {
    case destinationChanged(URL)
    case destinationInaccessible(URL, Int32)
    case destinationDirectoryChanged(URL)
    case destinationDirectoryInaccessible(URL, Int32)
    case destinationIsDirectory(URL)
    case destinationAliasesInput(URL, URL)
    case destinationBusy(URL)
    case lockFailed(URL, Int32)
    case restoreFailed(URL, recoveryURL: URL?, errno: Int32)
    case stagingChanged(URL)
    case sourceChanged(URL)
    case sourceInaccessible(URL, Int32)

    var errorDescription: String? {
        switch self {
        case .destinationChanged(let url):
            return "Die Zieldatei wurde seit der Bestätigung verändert: \(url.path)"
        case .destinationInaccessible(let url, let number):
            return "Die Zieldatei kann nicht sicher geprüft werden: \(url.path) (\(Self.reason(number)))"
        case .destinationDirectoryChanged(let url):
            return "Der Ausgabeordner wurde seit der Planung ersetzt: \(url.path)"
        case .destinationDirectoryInaccessible(let url, let number):
            return "Der Ausgabeordner kann nicht sicher geprüft werden: \(url.path) (\(Self.reason(number)))"
        case .destinationIsDirectory(let url):
            return "Der Zielpfad ist ein Ordner und wird nicht ersetzt: \(url.path)"
        case .destinationAliasesInput(let output, let input):
            return "Die Ausgabe verweist auf eine Eingabedatei: \(output.path) → \(input.path)"
        case .destinationBusy(let url):
            return "Ein anderer Hörbuchklöppler-Lauf verwendet bereits dieses Ziel: \(url.path)"
        case .lockFailed(let url, let number):
            return "Das Ziel konnte nicht exklusiv reserviert werden: \(url.path) (\(Self.reason(number)))"
        case .restoreFailed(let url, let recoveryURL, let number):
            let recovery = recoveryURL.map {
                " Der verdrängte Eintrag bleibt zur manuellen Wiederherstellung unter \($0.path) erhalten."
            } ?? ""
            return "Die zwischenzeitlich geänderte Zieldatei konnte nicht zurückgetauscht werden: \(url.path) (\(Self.reason(number))).\(recovery)"
        case .stagingChanged(let url):
            return "Die temporäre Ausgabedatei wurde während der Übernahme ausgetauscht und bleibt unangetastet: \(url.path)"
        case .sourceChanged(let url):
            return "Eine Eingabedatei wurde seit der Planung verändert: \(url.path)"
        case .sourceInaccessible(let url, let number):
            return "Eine Eingabedatei kann nicht sicher gelesen werden: \(url.path) (\(Self.reason(number)))"
        }
    }

    private static func reason(_ number: Int32) -> String {
        String(cString: strerror(number))
    }
}

/// Hält pro Ziel eine prozessübergreifende `fcntl`-Sperre. Die kleine versteckte
/// Lock-Datei bleibt absichtlich liegen: Würde ein Prozess sie beim Freigeben
/// löschen, könnte ein zweiter Prozess schon einen neuen Inode sperren, während
/// ein dritter noch den alten hält.
final class OutputLeaseSet: @unchecked Sendable {
    private var descriptors: [Int32]
    private let canonicalPaths: [String]

    init(descriptors: [Int32], canonicalPaths: [String]) {
        self.descriptors = descriptors
        self.canonicalPaths = canonicalPaths
    }

    deinit {
        for descriptor in descriptors {
            FFmpegWrapper.releaseOutputLock(descriptor)
        }
        FFmpegWrapper.releaseInProcessOutputPaths(canonicalPaths)
    }
}

extension FFmpegWrapper {
    static func fileSystemIdentity(
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

    static func captureSnapshot(
        of url: URL,
        followSymlink: Bool = false
    ) -> OutputDestinationSnapshot {
        if let identity = fileSystemIdentity(at: url, followSymlink: followSymlink) {
            return .existing(identity)
        }
        let errorNumber = errno
        return errorNumber == ENOENT || errorNumber == ENOTDIR
            ? .missing
            : .inaccessible(errno: errorNumber)
    }

    @discardableResult
    static func renameEntry(
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

    /// Nicht `private`: Der Ausgabeplan in `FFmpegWrapper.swift` muss Eingaben
    /// und Ziele nach genau derselben Regel vergleichen wie die Sperren hier.
    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Auf case-insensitiven Volumes müssen Schreibvarianten denselben
    /// Registry- und Lock-Schlüssel erhalten. Die explizite Variante hält die
    /// Normalisierung ohne besonderes Test-Volume prüfbar.
    static func outputLeaseKey(
        for output: URL,
        caseSensitiveNames: Bool? = nil
    ) -> String {
        let path = canonicalPath(output).precomposedStringWithCanonicalMapping
        let parent = output.deletingLastPathComponent()
        let caseSensitive = caseSensitiveNames
            ?? (try? parent.resourceValues(
                forKeys: [.volumeSupportsCaseSensitiveNamesKey]
            ))?.volumeSupportsCaseSensitiveNames
            ?? false
        guard !caseSensitive else { return path }
        return path.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    /// Stabiler Hash für kurze Lock-Dateinamen. Die Sperrdatei liegt im selben
    /// Zielordner; dadurch gelten Zugriffsrechte und Volume-Semantik des Ziels.
    static func outputLockURL(
        for output: URL,
        caseSensitiveNames: Bool? = nil
    ) -> URL {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in outputLeaseKey(
            for: output,
            caseSensitiveNames: caseSensitiveNames
        ).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let name = String(format: ".hoerbuchkloeppler-%016llx.lock", hash)
        return output.deletingLastPathComponent().appendingPathComponent(name)
    }

    static func acquireOutputLeases(for outputs: [URL]) throws -> OutputLeaseSet {
        let uniqueOutputs = Dictionary(
            outputs.map { (outputLeaseKey(for: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { outputLeaseKey(for: $0) < outputLeaseKey(for: $1) }
        let canonicalPaths = uniqueOutputs.map { outputLeaseKey(for: $0) }
        outputLeaseRegistryLock.lock()
        if let busyPath = canonicalPaths.first(where: { leasedOutputPaths.contains($0) }) {
            outputLeaseRegistryLock.unlock()
            let output = uniqueOutputs.first {
                outputLeaseKey(for: $0) == busyPath
            } ?? uniqueOutputs[0]
            throw ConversionOutputError.destinationBusy(output)
        }
        leasedOutputPaths.formUnion(canonicalPaths)
        outputLeaseRegistryLock.unlock()

        var descriptors: [Int32] = []

        func releaseAcquiredDescriptors() {
            for descriptor in descriptors {
                releaseOutputLock(descriptor)
            }
            descriptors.removeAll()
            releaseInProcessOutputPaths(canonicalPaths)
        }

        for output in uniqueOutputs {
            let lockURL = outputLockURL(for: output)
            let descriptor = lockURL.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else {
                    errno = EINVAL
                    return -1
                }
                return Darwin.open(
                    path,
                    O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o600)
                )
            }
            guard descriptor >= 0 else {
                let errorNumber = errno
                releaseAcquiredDescriptors()
                throw ConversionOutputError.lockFailed(output, errorNumber)
            }
            var fileLock = flock()
            fileLock.l_type = Int16(F_WRLCK)
            fileLock.l_whence = Int16(SEEK_SET)
            guard Darwin.fcntl(descriptor, F_SETLK, &fileLock) == 0 else {
                let errorNumber = errno
                _ = Darwin.close(descriptor)
                releaseAcquiredDescriptors()
                if errorNumber == EWOULDBLOCK || errorNumber == EAGAIN {
                    throw ConversionOutputError.destinationBusy(output)
                }
                throw ConversionOutputError.lockFailed(output, errorNumber)
            }
            descriptors.append(descriptor)
        }
        return OutputLeaseSet(
            descriptors: descriptors,
            canonicalPaths: canonicalPaths
        )
    }

    /// Gibt eine `fcntl`-Sperre frei und schließt ihren Deskriptor. Der
    /// Rückzug nach einem misslungenen Sperrsatz und das reguläre Ende über
    /// `OutputLeaseSet.deinit` müssen exakt dasselbe tun; sonst bliebe auf einem
    /// der beiden Wege eine Sperre oder ein Deskriptor stehen.
    static func releaseOutputLock(_ descriptor: Int32) {
        var fileLock = flock()
        fileLock.l_type = Int16(F_UNLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        _ = Darwin.fcntl(descriptor, F_SETLK, &fileLock)
        _ = Darwin.close(descriptor)
    }

    /// Öffnet genau den benannten Ordner als Deskriptor. `O_DIRECTORY` weist
    /// eine untergeschobene Datei ab, `O_NOFOLLOW` einen untergeschobenen
    /// Symlink — an dieser Flagkombination hängt die gesamte gebundene
    /// Bereinigung, deshalb steht sie nur an einer Stelle.
    static func openOwnedDirectory(_ url: URL) -> Int32 {
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

    static func releaseInProcessOutputPaths(_ paths: [String]) {
        outputLeaseRegistryLock.lock()
        leasedOutputPaths.subtract(paths)
        outputLeaseRegistryLock.unlock()
    }

    /// Versteckte Staging-Datei neben dem Ziel. Der Dateiname trägt die
    /// Besitzer-PID als überprüfbare Laufmarke: Nach SIGKILL/Absturz/Stromausfall
    /// kennt kein Kontext die Datei mehr, aber `removeOrphanedStagedOutputs`
    /// erkennt am toten Besitzer, dass die oft gigabytegroße Leiche weg darf.
    static func stagingOutputURL(
        for finalURL: URL,
        id: UUID = UUID(),
        ownerPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> URL {
        return hiddenSiblingURL(
            for: finalURL,
            marker: "partial-\(ownerPID)-\(id.uuidString)"
        )
    }

    /// Legt den späteren ffmpeg-Output exklusiv an und markiert genau diesen
    /// Inode per Extended Attribute. ffmpeg öffnet ihn mit `-y`/`O_TRUNC`; der
    /// Marker bleibt dabei erhalten. Ein untergeschobener Ersatz trägt ihn nicht
    /// und wird weder beim Abbruch noch durch die Altlastenbereinigung gelöscht.
    @discardableResult
    static func createOwnedStagingOutput(
        _ url: URL,
        ownerPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        setOwnershipMarker: (Int32, String) -> Int32 = setStagingOwnershipMarker
    ) throws -> StagingOwnership {
        let creation = try createOwnedStagingOutputAndDescriptor(
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

    private static func createOwnedStagingOutputAndDescriptor(
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
            _ = quarantineAndRemoveRegularFile(
                url,
                expectedIdentity: createdIdentity,
                cleanupPrefix: ".HB_StagingCleanup_",
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
        let markerUnsupported = markerResult != 0
            && (markerError == ENOTSUP || markerError == EOPNOTSUPP)
        guard markerResult == 0 || markerUnsupported,
              identityResult == 0 else {
            _ = Darwin.close(descriptor)
            _ = quarantineAndRemoveRegularFile(
                url,
                expectedIdentity: createdIdentity,
                cleanupPrefix: ".HB_StagingCleanup_",
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

    static func currentStagingOwnership(at url: URL) -> StagingOwnership? {
        guard let identity = fileSystemIdentity(at: url, followSymlink: false)
        else { return nil }
        let owner = stagedOutputOwnerPID(url)
            ?? ProcessInfo.processInfo.processIdentifier
        return StagingOwnership(
            identity: identity,
            ownerPID: owner,
            hasPersistentMarker: stagedOutputHasOwnershipMarker(
                url,
                expectedOwnerPID: owner
            ),
            protectedDirectory: nil,
            protectedDirectoryIdentity: nil
        )
    }

    /// Produktions-Staging liegt in einem exklusiv angelegten 0700-Ordner
    /// neben dem Ziel. ffmpeg erhält nur den Pfad innerhalb dieses Ordners;
    /// ein anderer Lauf oder ein Dateisynchronisierer kann den Ausgabepfad
    /// dadurch nicht am frei zugänglichen Zielordner austauschen.
    static func createProtectedStagingOutput(
        for finalURL: URL,
        ownerPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) throws -> StagingOutputHandle {
        let directory = finalURL.deletingLastPathComponent().appendingPathComponent(
            ".HB_StagingWork_\(ownerPID)-\(UUID().uuidString)"
        )
        try createOwnedTempDirectory(directory, ownerPID: ownerPID)
        guard let directoryIdentity = fileSystemIdentity(
            at: directory,
            followSymlink: false
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = directory.appendingPathComponent("entry.m4b")
        var expectedEntry: CleanupEntryRecord?
        var retainedDescriptor: Int32?
        do {
            let created = try createOwnedStagingOutputAndDescriptor(
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
            try writeCleanupEntryIdentity(
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
            removeOwnedTempDirectory(
                directory,
                expectedIdentity: directoryIdentity,
                expectedOwnerPID: ownerPID,
                expectedCleanupEntry: expectedEntry
            )
            throw error
        }
    }

    static func stagedOutputHasOwnershipMarker(
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

    static func clearStagingOwnershipMarker(_ url: URL) {
        _ = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return stagingOwnerAttribute.withCString { name in
                Darwin.removexattr(path, name, XATTR_NOFOLLOW)
            }
        }
    }

    /// Nicht `private`: Auch der Kodierpfad prüft damit unmittelbar vor dem
    /// ffmpeg-Start, dass die geschützte Ausgabedatei noch die eigene ist.
    static func stagingOwnershipMatches(
        _ ownership: StagingOwnership?,
        identity: FileSystemIdentity,
        at url: URL
    ) -> Bool {
        guard let ownership else { return true }
        return ownership.identity.matchesRegularFileEntry(identity)
            && (!ownership.hasPersistentMarker
                || stagedOutputHasOwnershipMarker(
                    url,
                    expectedOwnerPID: ownership.ownerPID
                ))
    }

    /// Entfernt eine eigene Partial-Datei über einen zufälligen
    /// Quarantänenamen. Nach dem atomaren Rename wird der am Inode haftende
    /// Besitzer-Marker erneut geprüft; ein ausgetauschter Eintrag wird
    /// zurückgestellt und bleibt unangetastet.
    @discardableResult
    static func removeOwnedStagedOutput(
        _ url: URL,
        expectedOwnership: StagingOwnership? = nil,
        log: @Sendable (String) -> Void = { _ in },
        afterQuarantine: ((URL) -> Void)? = nil,
        beforeRestore: (() -> Void)? = nil
    ) -> Bool {
        if captureSnapshot(of: url) == .missing { return true }
        let owner: pid_t
        let persistentMarker: Bool
        let createdIdentity: FileSystemIdentity?
        if let expectedOwnership {
            owner = expectedOwnership.ownerPID
            persistentMarker = expectedOwnership.hasPersistentMarker
            createdIdentity = expectedOwnership.identity
        } else if let parsedOwner = stagedOutputOwnerPID(url) {
            owner = parsedOwner
            persistentMarker = true
            createdIdentity = nil
        } else {
            log("⚠️ Staging-Eintrag hat keine gültige Besitzer-Markierung und bleibt liegen: \(url.path)")
            return false
        }
        guard case .existing(let current) = captureSnapshot(of: url),
              current.mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              createdIdentity?.matchesRegularFileEntry(current) ?? true,
              !persistentMarker || stagedOutputHasOwnershipMarker(
                url,
                expectedOwnerPID: owner
              ) else {
            log("⚠️ Staging-Eintrag hat keine gültige Besitzer-Markierung oder gehört nicht mehr zu diesem Lauf und bleibt liegen: \(url.path)")
            return false
        }
        return quarantineAndRemoveRegularFile(
            url,
            expectedIdentity: current,
            cleanupPrefix: ".HB_StagingCleanup_",
            ownerPID: owner,
            log: log,
            afterQuarantine: afterQuarantine,
            beforeRestore: beforeRestore
        )
    }

    @discardableResult
    static func removeProtectedStagingOutput(
        _ url: URL,
        ownership: StagingOwnership,
        log: @Sendable (String) -> Void = { _ in }
    ) -> Bool {
        guard let directory = ownership.protectedDirectory,
              let directoryIdentity = ownership.protectedDirectoryIdentity else {
            return removeOwnedStagedOutput(
                url,
                expectedOwnership: ownership,
                log: log
            )
        }
        if captureSnapshot(of: directory) == .missing { return true }
        if captureSnapshot(of: url) == .missing {
            return removeProtectedStagingDirectoryBound(
                directory,
                identity: directoryIdentity,
                ownership: ownership
            )
        }
        guard let current = fileSystemIdentity(at: url, followSymlink: false),
              ownership.identity.matchesRegularFileEntry(current),
              !ownership.hasPersistentMarker || stagedOutputHasOwnershipMarker(
                url,
                expectedOwnerPID: ownership.ownerPID
              ) else {
            log("⚠️ Geschütztes Staging wurde ausgetauscht und bleibt als Recovery-Rest liegen: \(directory.path)")
            return false
        }
        return removeProtectedStagingDirectoryBound(
            directory,
            identity: directoryIdentity,
            ownership: ownership
        )
    }

    @discardableResult
    static func removeEmptyProtectedStagingDirectory(
        ownership: StagingOwnership
    ) -> Bool {
        guard let directory = ownership.protectedDirectory,
              let directoryIdentity = ownership.protectedDirectoryIdentity else {
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
        if captureSnapshot(of: directory) == .missing { return true }
        guard let current = fileSystemIdentity(
            at: directory,
            followSymlink: false
        ),
        identity.matchesDirectoryEntry(current),
        temporaryDirectoryOwnerPID(directory) == ownership.ownerPID else {
            return false
        }
        let descriptor = openOwnedDirectory(directory)
        guard descriptor >= 0 else { return false }
        var boundInformation = stat()
        let boundMatches = Darwin.fstat(descriptor, &boundInformation) == 0
            && identity.matchesDirectoryEntry(
                FileSystemIdentity(stat: boundInformation)
            )
            && temporaryDirectoryOwnerPID(descriptor: descriptor)
                == ownership.ownerPID
        guard boundMatches else {
            _ = Darwin.close(descriptor)
            return false
        }
        let emptied = removeRecordedCleanupContentsBound(
            descriptor: descriptor,
            record: ownership.cleanupEntryRecord
        )
        _ = Darwin.close(descriptor)
        guard emptied,
              let stillVisible = fileSystemIdentity(
                at: directory,
                followSymlink: false
              ),
              identity.matchesDirectoryEntry(stillVisible) else {
            return false
        }
        let removed = removeEmptyDirectory(directory)
        return removed == 0 || errno == ENOENT
    }

    /// Gemeinsame Ableitung aller versteckten Nachbarnamen neben einem Ziel:
    /// führender Punkt, der auf `NAME_MAX` gekürzte Basisname, der jeweilige
    /// Marker und die Endung des Ziels. Staging- und Recovery-Namen dürfen sich
    /// nur im Marker unterscheiden — sonst greifen die Sweeps daneben, die
    /// genau an diesem Aufbau erkennen, was ihnen gehört.
    private static func hiddenSiblingURL(for finalURL: URL, marker: String) -> URL {
        let parent = finalURL.deletingLastPathComponent()
        let ext = finalURL.pathExtension.isEmpty ? "m4b" : finalURL.pathExtension
        return parent
            .appendingPathComponent(".\(stagingBasename(for: finalURL)).\(marker)")
            .appendingPathExtension(ext)
    }

    /// Recovery-Namen liegen bewusst außerhalb des `.partial-<PID>-`-Schemas:
    /// Die Altlastenbereinigung darf einen nach Rollback-Fehler geretteten
    /// fremden Eintrag auch nach einem Neustart niemals automatisch entfernen.
    static func recoveryOutputURL(for finalURL: URL, id: UUID = UUID()) -> URL {
        return hiddenSiblingURL(for: finalURL, marker: "recovery-\(id.uuidString)")
    }

    private static func preserveRecoveryEntry(
        from sourceURL: URL,
        for finalURL: URL,
        renameOperation: (URL, URL, UInt32) -> Int32
    ) -> URL? {
        for _ in 0..<4 {
            let recoveryURL = recoveryOutputURL(for: finalURL)
            if renameOperation(sourceURL, recoveryURL, UInt32(RENAME_EXCL)) == 0 {
                return recoveryURL
            }
            if errno != EEXIST { return nil }
        }
        return nil
    }

    /// Reserviert im Dateinamen Platz für Punkt, Marker, maximale PID, UUID und
    /// Endung. Die Kürzung arbeitet in UTF-8-Bytes, weil `NAME_MAX` Bytes und
    /// nicht Swift-Zeichen begrenzt.
    private static func stagingBasename(for finalURL: URL) -> String {
        let original = finalURL.deletingPathExtension().lastPathComponent
        let ext = finalURL.pathExtension.isEmpty ? "m4b" : finalURL.pathExtension
        let longestSuffix = ".partial-\(Int32.max)-00000000-0000-0000-0000-000000000000"
        let reservedBytes = 1 + longestSuffix.utf8.count + 1 + ext.utf8.count
        let limit = max(1, Int(NAME_MAX) - reservedBytes)
        var result = ""
        var byteCount = 0
        for character in original {
            let characterBytes = String(character).utf8.count
            if byteCount + characterBytes > limit { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result.isEmpty ? "output" : result
    }

    /// Liest die Besitzer-PID aus einem Staging-Dateinamen
    /// (`.<basename>.partial-<pid>-<uuid>.<ext>`). Liefert `nil` für das alte
    /// Format ohne PID und für alles, was keiner Staging-Datei ähnelt.
    static func stagedOutputOwnerPID(_ url: URL) -> pid_t? {
        let stem = url.deletingPathExtension().lastPathComponent
        // Von hinten suchen: Der Zieltitel selbst darf `.partial-` enthalten
        // (z.B. `Mein.partial-Buch.m4b` ergibt `.Mein.partial-Buch.partial-<pid>-<uuid>`).
        // Nur der letzte Marker ist der von uns angehängte; eine UUID enthält nie
        // `.partial-`, der Marker steht also garantiert am richtigen Platz.
        guard let range = stem.range(of: ".partial-", options: .backwards) else { return nil }
        let suffix = stem[range.upperBound...]
        guard let dash = suffix.firstIndex(of: "-"),
              let pid = pid_t(suffix[..<dash]),
              pid > 0,
              // Der Rest muss eine vollständige UUID sein. Das schließt das alte
              // Format `.partial-<uuid>` aus, dessen erste Zifferngruppe sonst
              // als PID durchginge.
              UUID(uuidString: String(suffix[suffix.index(after: dash)...])) != nil else {
            return nil
        }
        return pid
    }

    /// Entfernt verwaiste Staging-Dateien früherer Läufe für genau dieses Ziel.
    /// Verwaist = die im Namen vermerkte Besitzer-PID lebt nicht mehr. Dateien
    /// eines lebenden Prozesses (paralleler Lauf auf dasselbe Ziel) und Namen
    /// ohne PID-Marke bleiben unangetastet.
    static func removeOrphanedStagedOutputs(
        for finalURL: URL,
        caseSensitiveNames: Bool? = nil,
        log: @Sendable (String) -> Void = { _ in },
        beforeUnlink: ((URL) -> Void)? = nil
    ) {
        let fileManager = FileManager.default
        let parent = finalURL.deletingLastPathComponent()
        cleanupOutputQuarantines(in: parent, log: log)
        let basename = stagingBasename(for: finalURL)
        let prefix = ".\(basename).partial-"
        let expectedExtension = finalURL.pathExtension.isEmpty
            ? "m4b" : finalURL.pathExtension
        // Basisname und Endung müssen NACH DERSELBEN Regel verglichen werden,
        // und zwar nach der des Volumes: Auf einem case-insensitiven Volume
        // (macOS-Standard) sind `Buch.M4B` und `Buch.m4b` dasselbe Ziel, auf
        // einem case-sensitiven zwei verschiedene. Vorher wurde die Endung
        // immer kleingeschrieben verglichen, der Basisname aber immer exakt —
        // beides ging je nach Volume daneben (Review-Fund 2026-08-17).
        // Liefert das Volume die Eigenschaft nicht (bei Netz-/FUSE-Mounts
        // möglich), gilt das macOS-Standardverhalten: case-insensitiv.
        let caseSensitive = caseSensitiveNames
            ?? (try? parent.resourceValues(
                forKeys: [.volumeSupportsCaseSensitiveNamesKey]
            ))?.volumeSupportsCaseSensitiveNames
            ?? false
        func sameName(_ candidate: String, _ expected: String) -> Bool {
            caseSensitive ? candidate == expected
                : candidate.compare(expected, options: .caseInsensitive) == .orderedSame
        }
        func startsWithPrefix(_ candidate: String) -> Bool {
            caseSensitive ? candidate.hasPrefix(prefix)
                : candidate.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
        }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for url in contents where startsWithPrefix(url.lastPathComponent)
            && sameName(url.pathExtension, expectedExtension) {
            guard let owner = stagedOutputOwnerPID(url) else { continue }
            // Gleiche Lebend-Prüfung wie bei den Temp-Verzeichnissen: EPERM
            // heißt "existiert, gehört jemand anderem" — also nicht anfassen.
            if Darwin.kill(owner, 0) == 0 || errno == EPERM { continue }
            // Nur ein vom Erzeuger exklusiv angelegter und am Inode markierter
            // Eintrag ist unsere Altlast. Ein fremder Ersatz oder eine nach
            // fehlgeschlagenem Rollback verdrängte Zieldatei bleibt erhalten.
            guard stagedOutputHasOwnershipMarker(
                url,
                expectedOwnerPID: owner
            ) else {
                log("⚠️ Unmarkierter Staging-Eintrag bleibt liegen: \(url.path)")
                continue
            }
            // `contentsOfDirectory` liefert auch Ordner. Nie rekursiv löschen;
            // den liegengebliebenen Eintrag aber sichtbar melden.
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true else {
                log("⚠️ Staging-Eintrag ist keine reguläre Datei und bleibt liegen: \(url.path)")
                continue
            }
            // Der Hook macht im Test den Typwechsel nach der Prüfung
            // deterministisch. `unlink` entfernt genau diesen Verzeichniseintrag
            // und verweigert einen inzwischen eingesetzten Ordner atomar; anders
            // als `removeItem` kann es dessen Inhalt nicht rekursiv löschen.
            beforeUnlink?(url)
            ConversionContext.unlinkStagedOutput(url, log: log)
        }
    }

    /// Entfernt nach einem Prozessabsturz zurückgebliebene, exklusiv
    /// angelegte Cleanup-Verzeichnisse neben einem Ausgabeziel. Der exakte Name,
    /// die Besitzerdatei und ESRCH müssen gemeinsam einen toten Lauf belegen.
    static func cleanupOutputQuarantines(
        in parent: URL,
        log: @Sendable (String) -> Void = { _ in }
    ) {
        let prefixes = [
            ".HB_StagingWork_",
            ".HB_StagingCleanup_",
            ".HB_DisplacedCleanup_",
            ".HB_Cleanup_"
        ]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents {
            guard let prefix = prefixes.first(where: {
                url.lastPathComponent.hasPrefix($0)
            }) else { continue }
            let suffix = url.lastPathComponent.dropFirst(prefix.count)
            let parts = suffix.split(separator: "-", maxSplits: 1)
            guard parts.count == 2,
                  let owner = pid_t(parts[0]),
                  owner > 0,
                  UUID(uuidString: String(parts[1])) != nil,
                  let identity = fileSystemIdentity(at: url, followSymlink: false),
                  identity.mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  temporaryDirectoryOwnerPID(url) == owner else { continue }
            guard Darwin.kill(owner, 0) != 0, errno == ESRCH else { continue }
            guard let entryRecord = cleanupEntryRecord(in: url),
                  cleanupEntryMatchesRecordedIdentity(
                    entryRecord,
                    in: url
                  ) else {
                log("⚠️ Cleanup-Rest enthält keinen eindeutig eigenen Eintrag und bleibt liegen: \(url.path)")
                continue
            }
            removeOwnedTempDirectory(
                url,
                expectedIdentity: identity,
                expectedOwnerPID: owner,
                expectedCleanupEntry: entryRecord
            )
            if captureSnapshot(of: url) != .missing {
                log("⚠️ Verwaister Cleanup-Rest konnte nicht entfernt werden: \(url.path)")
            }
        }
    }

    static func writeCleanupEntryIdentity(
        _ identity: FileSystemIdentity,
        in cleanupDirectory: URL,
        filename: String = "entry",
        stableIdentityOnly: Bool = false,
        alternateIdentity: FileSystemIdentity? = nil,
        alternateStableIdentityOnly: Bool? = nil
    ) throws {
        let data = try JSONEncoder().encode(CleanupEntryRecord(
            identity: identity,
            filename: filename,
            stableIdentityOnly: stableIdentityOnly,
            alternateIdentity: alternateIdentity,
            alternateStableIdentityOnly: alternateStableIdentityOnly
        ))
        try data.write(
            to: cleanupDirectory.appendingPathComponent(
                cleanupEntryIdentityFilename
            ),
            options: .atomic
        )
    }

    private static func cleanupEntryRecord(
        in cleanupDirectory: URL
    ) -> CleanupEntryRecord? {
        let marker = cleanupDirectory.appendingPathComponent(
            cleanupEntryIdentityFilename
        )
        guard let data = try? Data(contentsOf: marker),
              let record = try? JSONDecoder().decode(
                CleanupEntryRecord.self,
                from: data
              ) else { return nil }
        return record
    }

    private static func cleanupEntryMatchesRecordedIdentity(
        _ record: CleanupEntryRecord,
        in cleanupDirectory: URL
    ) -> Bool {
        let entry = cleanupDirectory.appendingPathComponent(record.filename)
        switch captureSnapshot(of: entry) {
        case .missing:
            return true
        case .existing(let current):
            return record.matches(current)
        case .inaccessible:
            return false
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
        beforeQuarantine: (() -> Void)? = nil,
        afterQuarantine: ((URL) -> Void)? = nil,
        beforeRestore: (() -> Void)? = nil
    ) -> Bool {
        guard case .existing(let current) = captureSnapshot(of: url),
              expectedIdentity.matchesDisplacedEntry(current) else {
            if captureSnapshot(of: url) == .missing { return true }
            log("⚠️ Verdrängte Ausgabe wurde ausgetauscht und bleibt liegen: \(url.path)")
            return false
        }
        return quarantineAndRemoveRegularFile(
            url,
            expectedIdentity: expectedIdentity,
            cleanupPrefix: ".HB_DisplacedCleanup_",
            ownerPID: ProcessInfo.processInfo.processIdentifier,
            cleanupParent: cleanupParent,
            log: log,
            beforeQuarantine: beforeQuarantine,
            afterQuarantine: afterQuarantine,
            beforeRestore: beforeRestore
        )
    }

    /// Verschiebt eine geprüfte Einzeldatei in ein exklusiv angelegtes
    /// 0700-Cleanup-Verzeichnis. Die anschließende rekursive Entfernung ist an
    /// dessen offenen Deskriptor gebunden; ein Austausch des sichtbaren
    /// Quarantänepfads kann daher keine fremde Datei außerhalb dieses eigens
    /// angelegten Bereichs treffen. Ein absichtlicher Prozess derselben
    /// Unix-Benutzer-ID bleibt außerhalb dieser Schutzgrenze, weil `unlinkat`
    /// keinen erwarteten Inode als atomare Bedingung annimmt; Details stehen in
    /// `docs/operations.md`.
    @discardableResult
    private static func quarantineAndRemoveRegularFile(
        _ url: URL,
        expectedIdentity: FileSystemIdentity,
        cleanupPrefix: String,
        ownerPID: pid_t,
        cleanupParent: URL? = nil,
        log: @Sendable (String) -> Void,
        beforeQuarantine: (() -> Void)? = nil,
        afterQuarantine: ((URL) -> Void)? = nil,
        beforeRestore: (() -> Void)? = nil,
        stableIdentityOnly: Bool = false
    ) -> Bool {
        let sourceParent = url.deletingLastPathComponent()
        let cleanupDirectory = (cleanupParent ?? sourceParent).appendingPathComponent(
            "\(cleanupPrefix)\(ownerPID)-\(UUID().uuidString)"
        )
        do {
            try createOwnedTempDirectory(cleanupDirectory, ownerPID: ownerPID)
        } catch {
            log("⚠️ Cleanup-Verzeichnis konnte nicht angelegt werden: \(cleanupDirectory.path) (\(error.localizedDescription))")
            return false
        }
        guard let cleanupIdentity = fileSystemIdentity(
            at: cleanupDirectory,
            followSymlink: false
        ) else { return false }
        let entryRecord = CleanupEntryRecord(
            identity: expectedIdentity,
            filename: "entry",
            stableIdentityOnly: stableIdentityOnly
        )
        do {
            try writeCleanupEntryIdentity(
                expectedIdentity,
                in: cleanupDirectory,
                stableIdentityOnly: stableIdentityOnly
            )
        } catch {
            removeOwnedTempDirectory(
                cleanupDirectory,
                expectedIdentity: cleanupIdentity,
                expectedOwnerPID: ownerPID,
                expectedCleanupEntry: entryRecord
            )
            log("⚠️ Cleanup-Identität konnte nicht gesichert werden: \(cleanupDirectory.path) (\(error.localizedDescription))")
            return false
        }
        let quarantined = cleanupDirectory.appendingPathComponent("entry")
        beforeQuarantine?()
        guard renameEntry(
            from: url,
            to: quarantined,
            flags: UInt32(RENAME_EXCL)
        ) == 0 else {
            let number = errno
            removeOwnedTempDirectory(
                cleanupDirectory,
                expectedIdentity: cleanupIdentity,
                expectedOwnerPID: ownerPID
            )
            if number == ENOENT { return true }
            log("⚠️ Datei konnte nicht quarantänisiert werden: \(url.path) (\(String(cString: strerror(number))))")
            return false
        }
        let movedMatches: Bool
        if case .existing(let moved) = captureSnapshot(of: quarantined) {
            movedMatches = stableIdentityOnly
                ? expectedIdentity.matchesRegularFileEntry(moved)
                : expectedIdentity.matchesDisplacedEntry(moved)
        } else {
            movedMatches = false
        }
        guard movedMatches else {
            beforeRestore?()
            let restored = renameEntry(
                from: quarantined,
                to: url,
                flags: UInt32(RENAME_EXCL)
            ) == 0
            if restored {
                removeOwnedTempDirectory(
                    cleanupDirectory,
                    expectedIdentity: cleanupIdentity,
                    expectedOwnerPID: ownerPID,
                    expectedCleanupEntry: entryRecord
                )
                log("⚠️ Ausgetauschte Datei bleibt liegen: \(url.path)")
                return false
            }
            if let recoveryURL = preserveRecoveryEntry(
                from: quarantined,
                for: url,
                renameOperation: {
                    renameEntry(from: $0, to: $1, flags: $2)
                }
            ) {
                removeOwnedTempDirectory(
                    cleanupDirectory,
                    expectedIdentity: cleanupIdentity,
                    expectedOwnerPID: ownerPID,
                    expectedCleanupEntry: entryRecord
                )
                log("⚠️ Ausgetauschte Datei wurde unter einem Recovery-Namen gesichert: \(recoveryURL.path)")
                return false
            }
            let recoveryDirectory = sourceParent.appendingPathComponent(
                ".HB_RecoveryCleanup_\(UUID().uuidString)"
            )
            let recoveryDirectoryCreated = renameEntry(
                from: cleanupDirectory,
                to: recoveryDirectory,
                flags: UInt32(RENAME_EXCL)
            ) == 0
            if !recoveryDirectoryCreated {
                // Ohne gültige Besitzerdatei nimmt kein automatischer Sweep
                // diesen nicht eindeutig eigenen Eintrag mehr auf.
                let descriptor = openOwnedDirectory(cleanupDirectory)
                if descriptor >= 0 {
                    var information = stat()
                    if Darwin.fstat(descriptor, &information) == 0,
                       cleanupIdentity.matchesDirectoryEntry(
                        FileSystemIdentity(stat: information)
                       ) {
                        _ = tempOwnerFilename.withCString {
                            Darwin.unlinkat(descriptor, $0, 0)
                        }
                    }
                    _ = Darwin.close(descriptor)
                }
            }
            let remainingPath = recoveryDirectoryCreated
                ? recoveryDirectory.path : cleanupDirectory.path
            log("⚠️ Ausgetauschte Datei bleibt in einem Recovery-Cleanup-Verzeichnis erhalten: \(remainingPath)")
            return false
        }
        afterQuarantine?(cleanupDirectory)
        removeOwnedTempDirectory(
            cleanupDirectory,
            expectedIdentity: cleanupIdentity,
            expectedOwnerPID: ownerPID,
            expectedCleanupEntry: entryRecord
        )
        if captureSnapshot(of: cleanupDirectory) != .missing {
            log("⚠️ Cleanup-Rest bleibt bis zum nächsten Lauf liegen: \(cleanupDirectory.path)")
        }
        // Der geprüfte Eintrag liegt nicht mehr unter seinem produktiven
        // Namen. Ein seltener Cleanup-Rest ist deshalb kein Commit-Fehler.
        return true
    }

    static func regularFileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int64 else { return nil }
        return size > 0 ? size : nil
    }

    /// Setzt ein zuvor fehlendes Ziel mit `RENAME_EXCL` ein. Ein bestätigtes
    /// vorhandenes Ziel wird atomar mit der Staging-Datei getauscht; erst die
    /// danach tatsächlich verdrängte Datei wird gegen den Bestätigungs-Snapshot
    /// geprüft. Bei Abweichung tauscht die Funktion sofort zurück.
    @discardableResult
    static func commitStagedOutput(
        _ stagedURL: URL,
        to finalURL: URL,
        expectedDestination: OutputDestinationSnapshot,
        expectedDestinationDirectory: OutputDestinationSnapshot? = nil,
        expectedStagingOwnership: StagingOwnership? = nil,
        beforeRename: (() -> Void)? = nil,
        renameOperation: (URL, URL, UInt32) -> Int32 = {
            renameEntry(from: $0, to: $1, flags: $2)
        },
        unlinkDisplacedOutput: ((URL, FileSystemIdentity) -> Bool)? = nil
    ) throws -> Bool {
        guard case .existing(let expectedStagedIdentity) = captureSnapshot(of: stagedURL),
              expectedStagedIdentity.mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              expectedStagedIdentity.size > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let ownership = expectedStagingOwnership {
            guard stagingOwnershipMatches(
                ownership,
                identity: expectedStagedIdentity,
                at: stagedURL
            ) else {
                throw ConversionOutputError.stagingChanged(stagedURL)
            }
        }
        beforeRename?()
        if let expectedDestinationDirectory {
            try validateOutputDirectorySnapshot(
                for: finalURL,
                expected: expectedDestinationDirectory
            )
        }

        switch expectedDestination {
        case .missing:
            guard renameOperation(stagedURL, finalURL, UInt32(RENAME_EXCL)) == 0 else {
                let number = errno
                if number == EEXIST { throw ConversionOutputError.destinationChanged(finalURL) }
                throw POSIXError(POSIXErrorCode(rawValue: number) ?? .EIO)
            }
            guard case .existing(let movedIdentity) = captureSnapshot(of: finalURL),
                  expectedStagedIdentity.matchesDisplacedEntry(movedIdentity),
                  stagingOwnershipMatches(
                    expectedStagingOwnership,
                    identity: movedIdentity,
                    at: finalURL
                  ) else {
                guard renameOperation(finalURL, stagedURL, UInt32(RENAME_EXCL)) == 0 else {
                    let rollbackError = errno
                    let recoveryURL = preserveRecoveryEntry(
                        from: finalURL,
                        for: finalURL,
                        renameOperation: renameOperation
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
            guard captureSnapshot(of: finalURL) == .existing(expectedIdentity) else {
                throw ConversionOutputError.destinationChanged(finalURL)
            }
            guard expectedIdentity.mode & mode_t(S_IFMT) != mode_t(S_IFDIR) else {
                throw ConversionOutputError.destinationIsDirectory(finalURL)
            }
            if let ownership = expectedStagingOwnership,
               let protectedDirectory = ownership.protectedDirectory,
               let protectedIdentity = ownership.protectedDirectoryIdentity {
                guard let currentDirectory = fileSystemIdentity(
                    at: protectedDirectory,
                    followSymlink: false
                ),
                protectedIdentity.matchesDirectoryEntry(currentDirectory),
                temporaryDirectoryOwnerPID(protectedDirectory)
                    == ownership.ownerPID else {
                    throw ConversionOutputError.stagingChanged(stagedURL)
                }
                // Direkt nach RENAME_SWAP enthält entry.m4b das alte Ziel.
                // Ein Absturz in diesem Fenster darf den Staging-Ordner beim
                // nächsten Lauf trotzdem eindeutig als aufräumbar erkennen.
                try writeCleanupEntryIdentity(
                    ownership.identity,
                    in: protectedDirectory,
                    filename: stagedURL.lastPathComponent,
                    stableIdentityOnly: true,
                    alternateIdentity: expectedIdentity,
                    alternateStableIdentityOnly: false
                )
            }
            guard renameOperation(stagedURL, finalURL, UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let movedStagingMatches: Bool
            if case .existing(let movedIdentity) = captureSnapshot(of: finalURL) {
                movedStagingMatches = expectedStagedIdentity
                    .matchesDisplacedEntry(movedIdentity)
                    && stagingOwnershipMatches(
                        expectedStagingOwnership,
                        identity: movedIdentity,
                        at: finalURL
                    )
            } else {
                movedStagingMatches = false
            }
            let displacedDestinationMatches: Bool
            if case .existing(let displacedIdentity) = captureSnapshot(of: stagedURL) {
                displacedDestinationMatches = expectedIdentity
                    .matchesDisplacedEntry(displacedIdentity)
            } else {
                displacedDestinationMatches = false
            }
            guard movedStagingMatches, displacedDestinationMatches else {
                guard renameOperation(stagedURL, finalURL, UInt32(RENAME_SWAP)) == 0 else {
                    let rollbackError = errno
                    let recoveryURL = preserveRecoveryEntry(
                        from: stagedURL,
                        for: finalURL,
                        renameOperation: renameOperation
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
            // Das bestätigte alte Ziel liegt jetzt unter dem eindeutigen
            // Staging-Namen. `unlink` entfernt nur diesen Eintrag, nie rekursiv.
            return unlinkDisplacedOutput?(stagedURL, expectedIdentity)
                ?? removeDisplacedOutput(
                    stagedURL,
                    expectedIdentity: expectedIdentity,
                    cleanupParent: finalURL.deletingLastPathComponent()
                )
        }
    }

    static func createOwnedTempDirectory(
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
            _ = removeEmptyDirectory(url)
            throw error
        }
    }

    static func temporaryDirectoryOwnerPID(_ url: URL) -> pid_t? {
        let marker = url.appendingPathComponent(tempOwnerFilename)
        guard let text = try? String(contentsOf: marker, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return nil }
        return pid_t(pid)
    }

    private static func temporaryDirectoryOwnerPID(
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
              information.st_size <= 32 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(information.st_size))
        let count = bytes.withUnsafeMutableBytes {
            Darwin.read(markerDescriptor, $0.baseAddress, $0.count)
        }
        guard count == bytes.count,
              let text = String(bytes: bytes, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return nil }
        return pid_t(pid)
    }

    static func temporaryDirectoryHasLiveOwner(_ url: URL) -> Bool {
        guard let pid = temporaryDirectoryOwnerPID(url) else { return false }
        return Darwin.kill(pid_t(pid), 0) == 0 || errno == EPERM
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
                      }) == 0 else { return false }
            } else {
                guard name.withCString({
                    Darwin.unlinkat(directoryDescriptor, $0, 0)
                }) == 0 else { return false }
            }
        }
    }

    private static func cleanupEntryMatchesRecordedIdentity(
        _ record: CleanupEntryRecord,
        directoryDescriptor: Int32
    ) -> Bool {
        var information = stat()
        let result = record.filename.withCString {
            Darwin.fstatat(
                directoryDescriptor,
                $0,
                &information,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result != 0 { return errno == ENOENT }
        let current = FileSystemIdentity(stat: information)
        return record.matches(current)
    }

    private static func directoryEntryNames(
        descriptor: Int32
    ) -> [String]? {
        let duplicate = Darwin.dup(descriptor)
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

    /// Entfernt aus einem Ausgabe-Cleanup-Ordner ausschließlich die drei
    /// aufgezeichneten Einträge. Zusätzliche Dateien sind Recovery-Daten und
    /// verhindern jede automatische Löschung des Ordners.
    private static func removeRecordedCleanupContentsBound(
        descriptor: Int32,
        record: CleanupEntryRecord,
        beforeEntryQuarantine: ((Int32) -> Void)? = nil
    ) -> Bool {
        guard let names = directoryEntryNames(descriptor: descriptor) else {
            return false
        }
        // Der feste Zwischenname ist Teil des Crash-Protokolls: Stirbt der
        // Prozess nach dem Rename, erkennt der nächste Sweep genau diesen
        // Zustand und prüft dessen Inode erneut gegen denselben Datensatz.
        let quarantineName = ".HB_EntryCleanup"
        let allowed = Set([
            tempOwnerFilename,
            cleanupEntryIdentityFilename,
            record.filename,
            quarantineName
        ])
        let hasEntry = names.contains(record.filename)
        let hasQuarantine = names.contains(quarantineName)
        guard Set(names).isSubset(of: allowed),
              !(hasEntry && hasQuarantine) else { return false }

        var movedDuringThisCall = false
        if hasEntry {
            guard cleanupEntryMatchesRecordedIdentity(
                record,
                directoryDescriptor: descriptor
            ) else { return false }
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
            var movedInformation = stat()
            let inspected = quarantineName.withCString {
                Darwin.fstatat(
                    descriptor,
                    $0,
                    &movedInformation,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard inspected == 0,
                  record.matches(FileSystemIdentity(stat: movedInformation)) else {
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
            guard quarantineName.withCString({
                Darwin.unlinkat(descriptor, $0, 0)
            }) == 0 else { return false }
        }
        for marker in [cleanupEntryIdentityFilename, tempOwnerFilename]
        where names.contains(marker) {
            guard marker.withCString({
                Darwin.unlinkat(descriptor, $0, 0)
            }) == 0 else { return false }
        }
        return directoryEntryNames(descriptor: descriptor)?.isEmpty == true
    }

    static func removeOwnedTempDirectory(
        _ url: URL,
        expectedIdentity: FileSystemIdentity,
        expectedOwnerPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        beforeQuarantine: (() -> Void)? = nil,
        beforeBoundRemoval: (() -> Void)? = nil,
        beforeRecordedEntryQuarantine: ((Int32) -> Void)? = nil,
        expectedCleanupEntry: CleanupEntryRecord? = nil
    ) {
        guard let currentIdentity = fileSystemIdentity(at: url, followSymlink: false),
              expectedIdentity.matchesDirectoryEntry(currentIdentity),
              temporaryDirectoryOwnerPID(url) == expectedOwnerPID else { return }
        beforeQuarantine?()

        let quarantine = url.deletingLastPathComponent().appendingPathComponent(
            ".HB_Cleanup_\(expectedOwnerPID)-\(UUID().uuidString)"
        )
        guard renameEntry(
            from: url,
            to: quarantine,
            flags: UInt32(RENAME_EXCL)
        ) == 0 else { return }

        guard let movedIdentity = fileSystemIdentity(
            at: quarantine,
            followSymlink: false
        ),
        expectedIdentity.matchesDirectoryEntry(movedIdentity),
        temporaryDirectoryOwnerPID(quarantine) == expectedOwnerPID else {
            // Der Pfad wurde nach der Vorprüfung ausgetauscht. Den fremden
            // Eintrag atomar an seinen ursprünglichen Namen zurückstellen; bei
            // einem weiteren Rennen bleibt er sicher unter dem Quarantänenamen.
            _ = renameEntry(
                from: quarantine,
                to: url,
                flags: UInt32(RENAME_EXCL)
            )
            return
        }
        beforeBoundRemoval?()
        let descriptor = openOwnedDirectory(quarantine)
        guard descriptor >= 0 else { return }
        var boundInformation = stat()
        let boundMatches = Darwin.fstat(descriptor, &boundInformation) == 0
            && expectedIdentity.device == boundInformation.st_dev
            && expectedIdentity.inode == boundInformation.st_ino
            && boundInformation.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        guard boundMatches else {
            _ = Darwin.close(descriptor)
            return
        }
        if let expectedCleanupEntry {
            let emptied = removeRecordedCleanupContentsBound(
                descriptor: descriptor,
                record: expectedCleanupEntry,
                beforeEntryQuarantine: beforeRecordedEntryQuarantine
            )
            guard emptied else {
                // Der gebundene Ordner enthält zusätzliche oder ausgetauschte
                // Recovery-Daten. Die Besitzerdatei bleibt erhalten, damit ein
                // späterer Lauf den eigenen Rest erneut prüfen kann.
                _ = Darwin.close(descriptor)
                return
            }
            _ = Darwin.close(descriptor)
            _ = removeEmptyDirectory(quarantine)
            return
        }
        let emptied = removeDirectoryContentsBound(to: descriptor)
        _ = Darwin.close(descriptor)
        guard emptied else { return }
        // `rmdir` ist absichtlich nicht rekursiv: Wurde der sichtbare Pfad nach
        // dem gebundenen Leeren ausgetauscht, bleibt ein Ersatz mit Inhalt stehen.
        _ = removeEmptyDirectory(quarantine)
    }

    public static func cleanupOldTempDirectories() {
        cleanupOldTempDirectories(
            in: URL(fileURLWithPath: NSTemporaryDirectory()),
            now: Date()
        )
    }

    static func cleanupOldTempDirectories(in tempDir: URL, now: Date) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.creationDateKey], options: []) else { return }
        let oneDayAgo = now.addingTimeInterval(-24 * 3600)
        
        for url in contents {
            let name = url.lastPathComponent
            let isTempName = name.hasPrefix("HB_Temp_")
                && UUID(uuidString: String(name.dropFirst("HB_Temp_".count))) != nil
            let cleanupSuffix = name.hasPrefix(".HB_Cleanup_")
                ? String(name.dropFirst(".HB_Cleanup_".count)) : ""
            let cleanupParts = cleanupSuffix.split(separator: "-", maxSplits: 1)
            let cleanupOwner = cleanupParts.first.flatMap { pid_t($0) }
            let isCleanupName = cleanupParts.count == 2
                && cleanupOwner != nil
                && UUID(uuidString: String(cleanupParts[1])) != nil
            guard (isTempName || isCleanupName),
                  let resourceValues = try? url.resourceValues(forKeys: [.creationDateKey]),
                  let creationDate = resourceValues.creationDate,
                  creationDate < oneDayAgo,
                  let identity = fileSystemIdentity(at: url, followSymlink: false),
                  identity.mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  let owner = temporaryDirectoryOwnerPID(url),
                  !isCleanupName || cleanupOwner == owner else { continue }
            // Nur ESRCH beweist, dass der markierte Besitzer nicht mehr lebt.
            guard Darwin.kill(owner, 0) != 0, errno == ESRCH else { continue }
            removeOwnedTempDirectory(
                url,
                expectedIdentity: identity,
                expectedOwnerPID: owner
            )
        }
    }
}
