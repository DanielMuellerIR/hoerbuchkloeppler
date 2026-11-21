import Foundation
import Darwin
import os

/// Hält pro Ziel eine prozessübergreifende `fcntl`-Sperre. Die kleine versteckte
/// Lock-Datei bleibt absichtlich liegen: Würde ein Prozess sie beim Freigeben
/// löschen, könnte ein zweiter Prozess schon einen neuen Inode sperren, während
/// ein dritter noch den alten hält.
final class OutputLeaseSet: Sendable {
    private let descriptors: [Int32]
    private let canonicalPaths: [String]

    init(descriptors: [Int32], canonicalPaths: [String]) {
        self.descriptors = descriptors
        self.canonicalPaths = canonicalPaths
    }

    deinit {
        for descriptor in descriptors {
            OutputLeases.releaseOutputLock(descriptor)
        }
        OutputLeases.releaseInProcessOutputPaths(canonicalPaths)
    }
}

enum OutputLeases {
    // POSIX-Satzsperren wirken zwischen Prozessen. Das Register schützt
    // deshalb auch zwei gleichzeitige Sitzungen desselben App-Prozesses.
    private static let registry = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Auf case-insensitiven Volumes müssen Schreibvarianten denselben
    /// Registry- und Lock-Schlüssel erhalten. Die explizite Variante hält die
    /// Normalisierung ohne besonderes Test-Volume prüfbar.
    static func outputLeaseKey(
        for output: URL,
        caseSensitiveNames: Bool? = nil
    ) -> String {
        let path = FFmpegWrapper.canonicalPath(output).precomposedStringWithCanonicalMapping
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
        outputLockURL(for: output, key: outputLeaseKey(for: output, caseSensitiveNames: caseSensitiveNames))
    }

    private static func outputLockURL(for output: URL, key: String) -> URL {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let name = String(format: ".hoerbuchkloeppler-%016llx.lock", hash)
        return output.deletingLastPathComponent().appendingPathComponent(name)
    }

    static func acquire(for outputs: [URL]) throws -> OutputLeaseSet {
        let targets = Dictionary(
            outputs.map { (outputLeaseKey(for: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        ).sorted { $0.key < $1.key }
        let keys = targets.map(\.key)
        try registry.withLock { activeKeys in
            if let busy = targets.first(where: { activeKeys.contains($0.key) }) {
                throw ConversionOutputError.destinationBusy(busy.value)
            }
            activeKeys.formUnion(keys)
        }

        var descriptors: [Int32] = []

        func releaseAcquiredDescriptors() {
            for descriptor in descriptors {
                releaseOutputLock(descriptor)
            }
            descriptors.removeAll()
            releaseInProcessOutputPaths(keys)
        }

        for (key, output) in targets {
            let lockURL = outputLockURL(for: output, key: key)
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
            canonicalPaths: keys
        )
    }

    /// Gibt eine `fcntl`-Sperre frei und schließt ihren Deskriptor. Der
    /// Rückzug nach einem misslungenen Sperrsatz und das reguläre Ende über
    /// `OutputLeaseSet.deinit` müssen exakt dasselbe tun; sonst bliebe auf einem
    /// der beiden Wege eine Sperre oder ein Deskriptor stehen.
    fileprivate static func releaseOutputLock(_ descriptor: Int32) {
        var fileLock = flock()
        fileLock.l_type = Int16(F_UNLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        _ = Darwin.fcntl(descriptor, F_SETLK, &fileLock)
        _ = Darwin.close(descriptor)
    }

    fileprivate static func releaseInProcessOutputPaths(_ keys: [String]) {
        registry.withLock { $0.subtract(keys) }
    }
}
