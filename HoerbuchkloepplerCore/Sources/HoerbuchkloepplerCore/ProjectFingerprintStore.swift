import Foundation
import os

/// Ein Hash gilt nur für denselben Datei-Snapshot.
final class ProjectFingerprintStore: Sendable {
    enum Verification {
        case unchanged(FileSystemIdentity)
        case changed, unreadable
    }

    enum ReadPolicy {
        case cachedOnly, synchronous, verifyCurrent
    }

    private let entries = OSAllocatedUnfairLock(initialState: [URL: (identity: FileSystemIdentity, sha256: String)]())

    func fingerprint(_ url: URL) throws -> String {
        guard let identity = readableIdentity(at: url) else {
            throw ProjectError.invalid("Quelle fehlt: \(url.lastPathComponent)")
        }
        let key = url.standardizedFileURL
        if let cached = entries.withLock({ $0[key] }), cached.identity == identity {
            return cached.sha256
        }
        return try readFingerprint(at: url, identity: identity)
    }

    func verify(_ url: URL, expectedSHA256: String, policy: ReadPolicy) -> Verification {
        guard let identity = readableIdentity(at: url) else { return .unreadable }
        let key = url.standardizedFileURL
        let cached = entries.withLock { $0[key] }
        if let cached, cached.identity == identity {
            return cached.sha256 == expectedSHA256 ? .unchanged(identity) : .changed
        }
        // Ungeprüfte Quellen dürfen einen synchronen Start nicht passieren.
        if policy == .cachedOnly { return cached == nil ? .unreadable : .changed }
        // Eine wiederhergestellte mtime kann einen gleich großen Inhaltswechsel
        // verdecken. Nur ein erneuter Hash unterscheidet ihn von einem Finder-Tag.
        if policy == .synchronous, let cached, !cached.identity.matchesContentSnapshot(identity) { return .changed }
        guard let sha256 = try? readFingerprint(at: url, identity: identity) else { return .unreadable }
        return sha256 == expectedSHA256 ? .unchanged(identity) : .changed
    }

    private func readFingerprint(at url: URL, identity: FileSystemIdentity) throws -> String {
        let fingerprint = try ProjectSource.fingerprintSnapshot(url)
        guard fingerprint.identity == identity, readableIdentity(at: url) == identity else {
            throw ProjectError.invalid("Quelle wurde während der Prüfung verändert.")
        }
        let key = url.standardizedFileURL
        entries.withLock { $0[key] = fingerprint }
        return fingerprint.sha256
    }

    private func readableIdentity(at url: URL) -> FileSystemIdentity? {
        guard let identity = FileSystemEntry.identity(at: url, followSymlink: true),
              FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return identity
    }
}
