import Foundation

struct FileDiscoveryResult: Sendable {
    let files: [FoundFile]
    let failureDescription: String?
}

/// `DirectoryEnumerator` darf seinen Fehler-Handler nebenläufig aufrufen. Der
/// Recorder hält deshalb nur den ersten Fehler hinter einer kleinen Sperre fest.
private final class DirectoryScanFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var firstFailure: String?

    func record(url: URL, error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard firstFailure == nil else { return }
        firstFailure = "\(url.path): \(error.localizedDescription)"
    }

    func snapshot() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return firstFailure
    }
}

enum SourceDiscovery {
    /// Löst genau einen Dateipfad nach denselben Regeln wie der Ordnerscan auf.
    /// Verzeichnis- und defekte Symlinks sind keine importierbaren Dateien.
    static func foundFile(at url: URL) -> FoundFile? {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return nil }
        if values.isRegularFile == true {
            return FoundFile(source: url, resolved: url)
        }
        guard values.isSymbolicLink == true else { return nil }
        let resolved = url.resolvingSymlinksInPath()
        guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?
            .isRegularFile == true else { return nil }
        return FoundFile(source: url, resolved: resolved)
    }

    /// Entfernt physische Dubletten. Ein bewusst benannter Symlink gewinnt
    /// gegen die danebenliegende Zieldatei; bei mehreren Links bleibt der erste
    /// Enumerator-Treffer erhalten.
    static func deduplicateFoundFiles(
        _ files: [FoundFile]
    ) -> (files: [FoundFile], discarded: [FoundFile]) {
        var kept: [FoundFile] = []
        var indexByTarget: [String: Int] = [:]
        var discarded: [FoundFile] = []
        for file in files {
            let target = file.resolved.standardizedFileURL.path
            guard let index = indexByTarget[target] else {
                indexByTarget[target] = kept.count
                kept.append(file)
                continue
            }
            if file.isSymbolicLink, !kept[index].isSymbolicLink {
                discarded.append(kept[index])
                kept[index] = file
            } else {
                discarded.append(file)
            }
        }
        return (kept, discarded)
    }

    /// Dedupliziert auch über getrennt eintreffende Drop-Provider hinweg. Alle
    /// Kapitel derselben Containerdatei bleiben als Gruppe erhalten; ein
    /// sichtbarer Symlink gewinnt wie beim Ordnerscan gegen das direkte Ziel.
    static func deduplicateAudioFiles(
        _ files: [AudioFile]
    ) -> (files: [AudioFile], discardedSources: [(discarded: URL, kept: URL)]) {
        var selectedSourceByTarget: [String: URL] = [:]
        for file in files {
            let target = file.url.standardizedFileURL.path
            let source = file.sourceURL.standardizedFileURL
            guard let selected = selectedSourceByTarget[target] else {
                selectedSourceByTarget[target] = source
                continue
            }
            let selectedIsLink = selected.path != target
            let candidateIsLink = source.path != target
            if candidateIsLink && !selectedIsLink {
                selectedSourceByTarget[target] = source
            }
        }

        var reportedDiscardedSources = Set<String>()
        var seenSegments = Set<String>()
        var discardedSources: [(discarded: URL, kept: URL)] = []
        let kept = files.filter { file in
            let target = file.url.standardizedFileURL.path
            guard let selected = selectedSourceByTarget[target] else { return false }
            let source = file.sourceURL.standardizedFileURL
            if source != selected {
                let reportKey = "\(target)\u{0}\(source.path)"
                if reportedDiscardedSources.insert(reportKey).inserted {
                    discardedSources.append((discarded: source, kept: selected))
                }
                return false
            }
            // Derselbe Provider darf dasselbe Kapitel nicht mehrfach liefern.
            // Start und Dauer gehören zum Schlüssel, damit unterschiedliche
            // Kapitel desselben m4b/mp4-Containers erhalten bleiben.
            let segmentKey = "\(target)\u{0}\(source.path)\u{0}"
                + "\(file.startTime.bitPattern)\u{0}\(file.duration.bitPattern)"
            guard seenSegments.insert(segmentKey).inserted else {
                let reportKey = "duplicate\u{0}\(segmentKey)"
                if reportedDiscardedSources.insert(reportKey).inserted {
                    discardedSources.append((discarded: source, kept: selected))
                }
                return false
            }
            return true
        }
        return (kept, discardedSources)
    }

    /// `FileManager.DirectoryEnumerator` ist absichtlich nicht über einen
    /// asynchronen Aufruf hinweg haltbar. Die Dateiliste wird deshalb synchron
    /// aufgebaut, prüft den laufbezogenen Abbruch aber vor und nach jedem
    /// `nextObject()`, damit auch ein großer Ordnerscan sofort enden kann.
    static func discoverFileURLs(
        in url: URL,
        cancellationRequested: () -> Bool = { false }
    ) -> FileDiscoveryResult {
        guard !cancellationRequested() else {
            return FileDiscoveryResult(files: [], failureDescription: nil)
        }
        let failureRecorder = DirectoryScanFailureRecorder()
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { failedURL, error in
                failureRecorder.record(url: failedURL, error: error)
                // Bei einem Lesefehler wäre jedes Teilergebnis potenziell ein
                // Hörbuch mit fehlenden Kapiteln. Deshalb sofort stoppen.
                return false
            }
        ) else {
            return FileDiscoveryResult(
                files: [],
                failureDescription: "\(url.path): Ordner kann nicht gelesen werden."
            )
        }

        var files: [FoundFile] = []
        while !cancellationRequested() {
            guard let item = enumerator.nextObject() else { break }
            guard !cancellationRequested() else { break }
            guard let fileURL = item as? URL else { continue }
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
            } catch {
                failureRecorder.record(url: fileURL, error: error)
                break
            }

            if values.isRegularFile == true {
                files.append(FoundFile(source: fileURL, resolved: fileURL))
                continue
            }
            guard values.isSymbolicLink == true else { continue }
            // Verzeichnis-Symlinks nie als Rekursionsweg verwenden. Ein
            // Dateisymlink wird dagegen bis zur regulären Zieldatei aufgelöst;
            // AVFoundation liefert für den Linkpfad selbst nicht zuverlässig
            // Dauer und Metadaten. Der LINKNAME bleibt trotzdem erhalten: er
            // bestimmt Reihenfolge und Kapiteltitel, sonst gäbe eine Sammlung
            // aus `01.wav -> Original-B.wav`, `02.wav -> Original-A.wav` die
            // vom Nutzer festgelegte Reihenfolge auf (Review-Fund 2026-08-17).
            enumerator.skipDescendants()
            if let found = foundFile(at: fileURL) { files.append(found) }
        }
        if let failure = failureRecorder.snapshot() {
            return FileDiscoveryResult(files: [], failureDescription: failure)
        }
        return FileDiscoveryResult(files: files, failureDescription: nil)
    }

    /// Vergleicht den gesamten sichtbaren Pfad komponentenweise in natürlicher
    /// Finder-Reihenfolge. Dadurch bleiben `CD1/01`, `CD1/02`, `CD2/01` und
    /// `CD2/02` gruppiert. Kapitel derselben Quelldatei folgen erst danach ihrer
    /// Startzeit.
    static func audioFileComesBefore(_ left: AudioFile, _ right: AudioFile) -> Bool {
        if left.sourceURL == right.sourceURL {
            return left.startTime < right.startTime
        }

        let leftComponents = left.sourceURL.standardizedFileURL.pathComponents
        let rightComponents = right.sourceURL.standardizedFileURL.pathComponents
        for (leftComponent, rightComponent) in zip(leftComponents, rightComponents) {
            let natural = leftComponent.localizedStandardCompare(rightComponent)
            if natural != .orderedSame { return natural == .orderedAscending }
            // `localizedStandardCompare` kann unterschiedliche Schreibweisen
            // gleich behandeln. Der literale Tiebreak erhält eine stabile,
            // strenge Reihenfolge, ohne vorzeitig die Kapitelzeit zu benutzen.
            let literal = leftComponent.compare(rightComponent, options: .literal)
            if literal != .orderedSame { return literal == .orderedAscending }
        }
        if leftComponents.count != rightComponents.count {
            return leftComponents.count < rightComponents.count
        }
        return left.url.path < right.url.path
    }
}
