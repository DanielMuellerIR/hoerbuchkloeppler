import Foundation
import AVFoundation
import ImageIO
import Darwin

enum ChapterExtractionResult: Sendable {
    case files([AudioFile])
    case failed(AudioImportFailure.Reason)
    case cancelled
}

extension AudioFile {
    /// Selbst eine beschädigte Datei darf die Kapitelanalyse nicht mit einer
    /// beliebig großen ffmetadata-Ausgabe im Speicher wachsen lassen. Acht MiB
    /// reichen auch bei sehr vielen Kapiteln um Größenordnungen aus.
    static let maximumFFMetadataByteCount = 8 * 1024 * 1024
    static let chapterExtractionTimeout: TimeInterval = 30

    /// Extrahiert das eingebettete Cover aus einer Audiodatei.
    /// Nutzt sowohl Common-Keys als auch Raw-Keys für maximale Kompatibilität (MP3, M4A, etc.)
    public static func extractEmbeddedArtwork(from url: URL) async -> Data? {
        guard !taskCancellationRequested() else { return nil }
        let asset = AVAsset(url: url)

        guard let metadata = try? await asset.load(.metadata) else { return nil }
        guard !taskCancellationRequested() else { return nil }
        for item in metadata {
            guard !taskCancellationRequested() else { return nil }
            // 1. Prüfung über CommonKey (Standardweg)
            if let commonKey = item.commonKey?.rawValue, (commonKey == "artwork" || commonKey == "cover") {
                let data = try? await item.load(.dataValue)
                guard !taskCancellationRequested() else { return nil }
                if let data = validatedEmbeddedArtworkData(data) { return data }
            }
            
            // 2. Prüfung über den rohen Key (oft nötig für ID3/MP3)
            if let key = item.key {
                let keyString = String(describing: key).lowercased()
                guard keyString.contains("artwork") || keyString.contains("cover") else { continue }
                let data = try? await item.load(.dataValue)
                guard !taskCancellationRequested() else { return nil }
                if let data = validatedEmbeddedArtworkData(data) { return data }
            }
        }
        return nil
    }

    /// Übernimmt für eingebettete Cover dieselbe Größen- und Decode-Grenze wie
    /// der Dateipfad für ein manuell gewähltes Cover. Ein kaputter erster
    /// Artwork-Tag darf die Suche nach einem späteren gültigen Tag nicht beenden.
    static func validatedEmbeddedArtworkData(_ data: Data?) -> Data? {
        guard let data,
              !data.isEmpty,
              data.count <= FFmpegWrapper.maximumCoverByteCount,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, options) != nil else {
            return nil
        }
        return data
    }

    /// Analysiert m4b/mp4 Dateien mit dem **gebündelten** `ffmpeg` und extrahiert
    /// die Kapitelstruktur. Nutzt absichtlich kein `ffprobe` — das ist NICHT
    /// mitgeliefert und fehlt auf Maschinen ohne Homebrew, wodurch m4b-Kapitel
    /// in der verteilten App verloren gingen. `ffmpeg -f ffmetadata -` schreibt
    /// die Metadaten (inkl. `[CHAPTER]`-Blöcke) nach stdout.
    public static func extractChapters(from file: FoundFile) async -> [AudioFile]? {
        guard file.isChapterContainer else { return nil }
        switch await extractChaptersControlled(from: file) {
        case .files(let files): return files
        case .failed: return []
        case .cancelled: return []
        }
    }

    /// Variante für `ConversionSession`: Sie registriert den gestarteten
    /// ffmpeg-Prozess beim laufbezogenen Vorbereitungs-Context und leitet
    /// Meldungen in das gemeinsame Session-Log statt direkt auf stdout.
    static func extractChaptersControlled(
        from file: FoundFile,
        shouldCancel: @Sendable () -> Bool = { false },
        configureProcess: @Sendable (Process) -> Void = { _ in },
        runProcess: @Sendable (Process) throws -> Bool = { process in
            try process.run()
            ProcessTerminator.recordOwnedProcessGroup(process)
            return true
        },
        unregisterProcess: @Sendable (Process) -> Void = {
            ProcessTerminator.forgetOwnedProcessGroup($0)
        },
        log: @Sendable (String) -> Void = { _ in }
    ) async -> ChapterExtractionResult {
        let url = file.readURL
        let visibleURL = file.source
        guard file.isChapterContainer else { return .files([]) }
        guard !shouldCancel(), !taskCancellationRequested() else { return .cancelled }

        guard let ffmpegURL = FFmpegWrapper.getBinaryURL(name: "ffmpeg") else {
            log("⚠️ ffmpeg wurde nicht gefunden. Kapitel-Extraktion übersprungen.")
            return .files([await AudioFile(foundFile: file)])
        }

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = ["-nostdin", "-v", "quiet", "-i", url.path, "-f", "ffmetadata", "-"]
        // Der Test kann hier einen kontrollierten Ersatzprozess einsetzen. Die
        // Produktionsaufrufer lassen die vorbereitete ffmpeg-Konfiguration
        // unverändert.
        configureProcess(process)

        let pipe = Pipe()
        process.standardOutput = pipe
        // stderr getrennt verwerfen, damit es weder die Metadaten-Ausgabe stört
        // noch in einer ungelesenen Pipe den Kindprozess blockieren kann.
        process.standardError = FileHandle.nullDevice

        return await withTaskCancellationHandler {
            do {
                guard !shouldCancel(), !taskCancellationRequested() else { return .cancelled }
                guard try runProcess(process) else { return .cancelled }
                defer { unregisterProcess(process) }
                try? pipe.fileHandleForWriting.close()
                // Cancel kann genau zwischen dem letzten Check und `run()` liegen.
                // Der Context hat den damals noch nicht laufenden Process dann nicht
                // beendet; nach dem Start deshalb nochmals prüfen.
                if shouldCancel() || taskCancellationRequested() {
                    ProcessTerminator.requestTermination(process)
                }
                // Erst die Pipe leeren, DANN auf Exit warten — sonst Deadlock, wenn
                // die Kapitelliste den Pipe-Puffer (~64 KB) füllt. Die Datenmenge
                // bleibt begrenzt; bei Überschreitung beendet der Leser ffmpeg und
                // kehrt ohne weitere Datenübernahme zurück.
                let extractionStart = DispatchTime.now().uptimeNanoseconds
                let output = readFFMetadata(
                    from: pipe.fileHandleForReading,
                    timeout: chapterExtractionTimeout
                ) {
                    // Synchron beenden: Danach darf `waitUntilExit()` nicht an
                    // einem hängenden direkten Kindprozess festbleiben.
                    ProcessTerminator.terminateAndWait([process])
                }
                let extractionElapsed = TimeInterval(
                    DispatchTime.now().uptimeNanoseconds - extractionStart
                ) / 1_000_000_000
                let processExited = waitForProcessExit(
                    process,
                    timeout: max(0, chapterExtractionTimeout - extractionElapsed)
                )
                if !processExited {
                    ProcessTerminator.terminateAndWait([process])
                }
                process.waitUntilExit()
                try? pipe.fileHandleForReading.close()
                guard !shouldCancel(), !taskCancellationRequested() else { return .cancelled }
                guard !output.timedOut, processExited else {
                    log("⚠️ Kapitelanalyse für \(visibleURL.lastPathComponent) nach \(Int(chapterExtractionTimeout)) Sekunden abgebrochen. Datei wird übersprungen.")
                    return .failed(.chapterAnalysisTimedOut)
                }
                guard !output.readFailed else {
                    log("⚠️ Kapitelmetadaten aus \(visibleURL.lastPathComponent) konnten nicht vollständig gelesen werden. Nutze die Datei als ein Kapitel.")
                    return .files([await AudioFile(foundFile: file)])
                }
                guard !output.exceededLimit else {
                    log("⚠️ Kapitelmetadaten in \(visibleURL.lastPathComponent) überschreiten 8 MiB. Nutze die Datei als ein Kapitel.")
                    return .files([await AudioFile(foundFile: file)])
                }
                guard process.terminationStatus == 0 else {
                    log("⚠️ ffmpeg konnte Kapitel aus \(visibleURL.lastPathComponent) nicht vollständig lesen. Nutze die Datei als ein Kapitel.")
                    return .files([await AudioFile(foundFile: file)])
                }

                guard let text = String(data: output.data, encoding: .utf8) else {
                    log("⚠️ FFMETADATA von \(visibleURL.lastPathComponent) nicht lesbar. Nutze die Datei als ein Kapitel.")
                    return .files([await AudioFile(foundFile: file)])
                }
                var chapters = parseFFMetadataChapters(text)
                guard !chapters.isEmpty else {
                    log("⚠️ Keine Kapitel in \(visibleURL.lastPathComponent) gefunden. Nutze die Datei als ein Kapitel.")
                    return .files([await AudioFile(foundFile: file)])
                }

                let loadedDuration = try? await AVURLAsset(url: url).load(.duration)
                guard !shouldCancel(), !taskCancellationRequested() else { return .cancelled }
                let totalDuration = sanitizeDuration(loadedDuration.map(CMTimeGetSeconds) ?? 0)
                // Das LETZTE Kapitel hat in FFMETADATA oft keine END-Zeit — es gibt kein
                // Folgekapitel, aus dem sie (wie in parseFFMetadataChapters) abgeleitet
                // werden könnte. Ohne Korrektur bliebe es ein Null-Dauer-Kapitel, das ein
                // leeres Segment erzeugt und die GANZE Konvertierung scheitern lässt.
                // Deshalb die fehlende letzte END-Zeit aus der Gesamtdauer der Datei ableiten.
                if let last = chapters.indices.last, chapters[last].end <= chapters[last].start {
                    if totalDuration.isFinite, totalDuration > chapters[last].start {
                        chapters[last].end = totalDuration
                    }
                }

                // Eine teilweise kaputte Kapitelliste nicht in garantiert leere
                // `ffmpeg -t 0`-Segmente übersetzen. Der sichere Fallback ist die
                // komplette Datei als ein Kapitel; so scheitert nicht das ganze Buch.
                guard chaptersAreValid(chapters, totalDuration: totalDuration) else {
                    log("⚠️ Unvollständige Kapitelzeiten in \(visibleURL.lastPathComponent). Nutze die Datei als ein Kapitel.")
                    return .files([await AudioFile(foundFile: file)])
                }
                // Rundungsdifferenzen im FFMETADATA-Container lückenlos an die
                // tatsächliche Dateidauer anlegen.
                chapters[0].start = 0
                for index in chapters.indices.dropFirst() {
                    chapters[index].start = chapters[index - 1].end
                }
                if let last = chapters.indices.last { chapters[last].end = totalDuration }

                var audioFiles: [AudioFile] = []
                for (index, ch) in chapters.enumerated() {
                    let title = ch.title.isEmpty ? "Kapitel \(index + 1)" : ch.title
                    // AudioFile.init klemmt Dauer/startTime auf endlich und >= 0.
                    audioFiles.append(AudioFile(
                        foundFile: file,
                        startTime: ch.start,
                        duration: ch.end - ch.start,
                        chapterTitle: title
                    ))
                }
                log("✅ \(audioFiles.count) Kapitel aus \(visibleURL.lastPathComponent) extrahiert.")
                return .files(audioFiles)
            } catch {
                if shouldCancel() || taskCancellationRequested() { return .cancelled }
                log("⚠️ Kapitel aus \(visibleURL.lastPathComponent) konnten nicht gelesen werden: \(error.localizedDescription)")
                return .files([await AudioFile(foundFile: file)])
            }
        } onCancel: {
            ProcessTerminator.requestTermination(process)
        }
    }

    /// Wartet höchstens die verbleibende Kapitelanalyse-Frist auf den Prozess.
    /// EOF allein bedeutet nicht, dass ein fehlerhaftes Ersatzprogramm beendet ist.
    static func waitForProcessExit(_ process: Process, timeout: TimeInterval) -> Bool {
        // Eine nichtendliche Frist bedeutet hier ausdrücklich „gar nicht warten“;
        // die Kapitelanalyse deckelt zusätzlich bei einer Stunde.
        let boundedTimeout = timeout.isFinite ? min(max(0, timeout), 3_600) : 0
        return ProcessTerminator.wait(upTo: boundedTimeout) { process.isRunning }
    }

    /// Liest eine ffmetadata-Pipe bis zu einer festen Obergrenze und Frist.
    /// `poll` hält die Frist auch dann ein, wenn weder Daten noch EOF kommen.
    /// Beim ersten Grenzfehler beendet `onAbort` den direkten Kindprozess; der
    /// Leser kehrt danach sofort zurück und wartet nicht auf vererbte Pipe-Enden.
    static func readFFMetadata(
        from handle: FileHandle,
        maximumByteCount: Int = maximumFFMetadataByteCount,
        timeout: TimeInterval = chapterExtractionTimeout,
        onAbort: () -> Void = {}
    ) -> (data: Data, exceededLimit: Bool, timedOut: Bool, readFailed: Bool) {
        let limit = max(0, maximumByteCount)
        let boundedTimeout = timeout.isFinite ? min(max(0, timeout), 3_600) : chapterExtractionTimeout
        let timeoutNanoseconds = UInt64(boundedTimeout * 1_000_000_000)
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start > UInt64.max - timeoutNanoseconds
            ? UInt64.max
            : start + timeoutNanoseconds
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                onAbort()
                return (data, false, true, false)
            }
            let remainingNanoseconds = deadline - now
            let roundedMilliseconds = remainingNanoseconds / 1_000_000
                + (remainingNanoseconds % 1_000_000 == 0 ? 0 : 1)
            let remainingMilliseconds = max(
                1,
                min(50, Int(roundedMilliseconds))
            )
            var candidate = pollfd(
                fd: handle.fileDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = Darwin.poll(&candidate, 1, Int32(remainingMilliseconds))
            if pollResult == 0 { continue }
            if pollResult < 0 {
                if errno == EINTR { continue }
                onAbort()
                return (data, false, false, true)
            }
            let count = buffer.withUnsafeMutableBytes { storage in
                Darwin.read(handle.fileDescriptor, storage.baseAddress, storage.count)
            }
            if count == 0 { return (data, false, false, false) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                onAbort()
                return (data, false, false, true)
            }
            let byteCount = Int(count)
            guard byteCount <= limit - data.count else {
                onAbort()
                return (data, true, false, false)
            }
            data.append(contentsOf: buffer.prefix(byteCount))
        }
    }

    /// Ein aus FFMETADATA gelesenes Kapitel (Zeiten bereits in Sekunden).
    struct FFChapter { var start: TimeInterval = 0; var end: TimeInterval = 0; var title: String = "" }

    /// Parst die `[CHAPTER]`-Blöcke aus einer FFMETADATA-Ausgabe.
    /// ffmpeg schreibt TIMEBASE in jeden Block (Default 1/1000); zur Robustheit
    /// gegen ungewöhnliche/handgepflegte Dateien wird die TIMEBASE NICHT pro
    /// Kapitel hart zurückgesetzt, sondern vom Header bzw. vorherigen Kapitel
    /// geerbt. Fehlende END-Zeiten werden aus dem Start des Folgekapitels
    /// abgeleitet (sonst entstünde ein stilles Null-Dauer-Kapitel).
    static func parseFFMetadataChapters(_ text: String) -> [FFChapter] {
        var chapters: [FFChapter] = []
        var current: FFChapter?
        var tbNum: Double = 1, tbDen: Double = 1000
        var rawStart: Double?
        var rawEnd: Double?
        var sawEnd = false

        func parseTimebase(_ value: String) {
            let parts = value.trimmingCharacters(in: .whitespaces).split(separator: "/")
            guard parts.count == 2,
                  let numerator = Double(parts[0]), numerator.isFinite, numerator > 0,
                  let denominator = Double(parts[1]), denominator.isFinite, denominator > 0 else {
                // Ein vorhandener, aber kaputter Wert darf nicht still wie eine
                // fehlende TIMEBASE behandelt werden. NaN lässt die spätere
                // Kapitelvalidierung kontrolliert auf die ganze Datei zurückfallen.
                tbNum = .nan
                tbDen = 1
                return
            }
            tbNum = numerator
            tbDen = denominator
        }

        func flush() {
            guard var c = current else { return }
            let factor = tbNum / tbDen
            c.start = (rawStart ?? .nan) * factor
            c.end = sawEnd ? (rawEnd ?? .nan) * factor : c.start
            chapters.append(c)
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces) == "[CHAPTER]" {
                flush()
                current = FFChapter()
                rawStart = nil
                rawEnd = nil
                sawEnd = false   // TIMEBASE bewusst geerbt
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces).uppercased()
            let value = String(line[line.index(after: eq)...])
            // Vor dem ersten [CHAPTER]: nur ein evtl. globales TIMEBASE übernehmen.
            if current == nil {
                if key == "TIMEBASE" { parseTimebase(value) }
                continue
            }
            switch key {
            case "TIMEBASE": parseTimebase(value)
            case "START": rawStart = Double(value.trimmingCharacters(in: .whitespaces))
            case "END":
                sawEnd = true
                rawEnd = Double(value.trimmingCharacters(in: .whitespaces))
            case "TITLE": current?.title = unescapeFFMetadata(value)
            default: break
            }
        }
        flush()

        // Fehlende oder nichtpositive END-Zeiten aus dem Start des nächsten
        // Kapitels füllen. Nicht parsebare Werte bleiben NaN und damit ungültig.
        for i in chapters.indices where chapters[i].end <= chapters[i].start && i + 1 < chapters.count {
            chapters[i].end = chapters[i + 1].start
        }
        return chapters
    }

    static func chaptersAreValid(
        _ chapters: [FFChapter],
        totalDuration: TimeInterval,
        tolerance: TimeInterval = 0.25
    ) -> Bool {
        guard !chapters.isEmpty, totalDuration.isFinite, totalDuration > 0,
              abs(chapters[0].start) <= tolerance else { return false }
        var previousEnd: TimeInterval = 0
        let lastIndex = chapters.index(before: chapters.endIndex)
        for (index, chapter) in chapters.enumerated() {
            // Genau diese Grenzen verwendet die anschließende Normalisierung:
            // Start wird auf das vorherige Ende, das letzte Ende auf die echte
            // Dateidauer gesetzt. Auch dieses normalisierte Kapitel muss positiv
            // bleiben, nicht nur die ursprüngliche FFMETADATA-Spanne.
            let normalizedEnd = index == lastIndex ? totalDuration : chapter.end
            guard chapter.start.isFinite, chapter.end.isFinite,
                  chapter.start >= 0, chapter.end > chapter.start,
                  chapter.start < totalDuration,
                  abs(chapter.start - previousEnd) <= tolerance,
                  normalizedEnd > previousEnd,
                  chapter.end <= totalDuration + tolerance else { return false }
            previousEnd = chapter.end
        }
        return abs(previousEnd - totalDuration) <= tolerance
    }

    /// Macht FFMETADATA-Escapes rückgängig (`\=`, `\;`, `\#`, `\\` → Klartext).
    static func unescapeFFMetadata(_ s: String) -> String {
        var result = ""
        var escaped = false
        for ch in s {
            if escaped { result.append(ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else { result.append(ch) }
        }
        if escaped { result.append("\\") }
        return result
    }
}
