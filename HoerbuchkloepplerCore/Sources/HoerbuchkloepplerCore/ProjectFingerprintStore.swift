import Foundation

/// Ein Hash gilt nur für denselben Datei-Snapshot. GUI-Vorbereitung liest große
/// Quellen außerhalb des Main Actors; der Start prüft danach nur den Snapshot.
final class ProjectFingerprintStore: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [URL: (FileSystemIdentity, String)] = [:]

    func fingerprint(_ url: URL) throws -> String {
        guard let identity = FFmpegWrapper.fileSystemIdentity(at: url, followSymlink: true) else {
            throw ProjectError.invalid("Quelle fehlt: \(url.lastPathComponent)")
        }
        // Nur eine Inhaltsänderung entwertet den Hash. Ein Finder-Tag oder ein
        // `chmod` hebt allein die Statuszeit an und darf keinen erneuten
        // Lesevorgang über die ganze Datei auslösen.
        if let cached = lock.withLock({ entries[url] }), cached.0.matchesContentSnapshot(identity) { return cached.1 }
        let hash = try ProjectSource.fingerprint(url)
        guard FFmpegWrapper.fileSystemIdentity(at: url, followSymlink: true) == identity else {
            throw ProjectError.invalid("Quelle wurde während der Prüfung verändert.")
        }
        lock.withLock { entries[url] = (identity, hash) }
        return hash
    }

    /// Meldet, ob sich der Datei-INHALT seit dem gespeicherten Hash geändert
    /// haben kann. Reine Metadaten-Operationen zählen nicht: Sonst bliebe ein
    /// Finder-Tag als „Quelle wurde verändert" stehen, ohne dass je neu
    /// gehasht und der Fehlalarm damit aufgelöst würde.
    func changedSinceLastRead(_ url: URL) -> Bool {
        guard let cached = lock.withLock({ entries[url] }) else { return false }
        guard let current = FFmpegWrapper.fileSystemIdentity(at: url, followSymlink: true) else { return true }
        return !cached.0.matchesContentSnapshot(current)
    }
}
