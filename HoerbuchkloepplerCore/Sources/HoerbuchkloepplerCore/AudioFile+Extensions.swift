import Foundation
import AVFoundation

extension AudioFile {
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
                if let data { return data }
            }
            
            // 2. Prüfung über den rohen Key (oft nötig für ID3/MP3)
            if let key = item.key as? String, (key.contains("artwork") || key.contains("cover")) {
                let data = try? await item.load(.dataValue)
                guard !taskCancellationRequested() else { return nil }
                if let data { return data }
            }
        }
        return nil
    }

    /// Analysiert m4b/mp4 Dateien mit dem **gebündelten** `ffmpeg` und extrahiert
    /// die Kapitelstruktur. Nutzt absichtlich kein `ffprobe` — das ist NICHT
    /// mitgeliefert und fehlt auf Maschinen ohne Homebrew, wodurch m4b-Kapitel
    /// in der verteilten App verloren gingen. `ffmpeg -f ffmetadata -` schreibt
    /// die Metadaten (inkl. `[CHAPTER]`-Blöcke) nach stdout.
    public static func extractChapters(from file: FoundFile) async -> [AudioFile]? {
        await extractChaptersControlled(from: file)
    }

    /// Variante für `ConversionSession`: Sie registriert den gestarteten
    /// ffmpeg-Prozess beim laufbezogenen Vorbereitungs-Context und leitet
    /// Meldungen in das gemeinsame Session-Log statt direkt auf stdout.
    static func extractChaptersControlled(
        from file: FoundFile,
        shouldCancel: @Sendable () -> Bool = { false },
        registerProcess: @Sendable (Process) -> Bool = { _ in true },
        unregisterProcess: @Sendable (Process) -> Void = { _ in },
        log: @Sendable (String) -> Void = { _ in }
    ) async -> [AudioFile]? {
        let url = file.readURL
        let visibleURL = file.source
        guard file.isChapterContainer else { return nil }
        guard !shouldCancel(), !taskCancellationRequested() else { return [] }

        guard let ffmpegURL = FFmpegWrapper.getBinaryURL(name: "ffmpeg") else {
            log("⚠️ ffmpeg wurde nicht gefunden. Kapitel-Extraktion übersprungen.")
            return [await AudioFile(foundFile: file)]
        }

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = ["-nostdin", "-v", "quiet", "-i", url.path, "-f", "ffmetadata", "-"]

        let pipe = Pipe()
        process.standardOutput = pipe
        // stderr getrennt verwerfen, damit es die Metadaten-Ausgabe nicht stört.
        process.standardError = Pipe()
        guard registerProcess(process) else { return [] }
        defer { unregisterProcess(process) }

        do {
            guard !shouldCancel(), !taskCancellationRequested() else { return [] }
            try process.run()
            // Cancel kann genau zwischen dem letzten Check und `run()` liegen.
            // Der Context hat den damals noch nicht laufenden Process dann nicht
            // beendet; nach dem Start deshalb nochmals prüfen.
            if shouldCancel() { process.terminate() }
            // Erst die Pipe leeren, DANN auf Exit warten — sonst Deadlock, wenn
            // die Kapitelliste den Pipe-Puffer (~64 KB) füllt.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard !shouldCancel(), !taskCancellationRequested() else { return [] }

            guard let text = String(data: data, encoding: .utf8) else {
                log("⚠️ FFMETADATA von \(visibleURL.lastPathComponent) nicht lesbar. Nutze die Datei als ein Kapitel.")
                return [await AudioFile(foundFile: file)]
            }
            var chapters = parseFFMetadataChapters(text)
            guard !chapters.isEmpty else {
                log("⚠️ Keine Kapitel in \(visibleURL.lastPathComponent) gefunden. Nutze die Datei als ein Kapitel.")
                return [await AudioFile(foundFile: file)]
            }

            let loadedDuration = try? await AVURLAsset(url: url).load(.duration)
            guard !shouldCancel(), !taskCancellationRequested() else { return [] }
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
                return [await AudioFile(foundFile: file)]
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
            return audioFiles
        } catch {
            if shouldCancel() || taskCancellationRequested() { return [] }
            log("⚠️ Kapitel aus \(visibleURL.lastPathComponent) konnten nicht gelesen werden: \(error.localizedDescription)")
            return [await AudioFile(foundFile: file)]
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
        var rawStart: Double = 0
        var rawEnd: Double?   // nil = END fehlt -> später aus Folgekapitel ableiten

        func parseTimebase(_ value: String) {
            let parts = value.trimmingCharacters(in: .whitespaces).split(separator: "/")
            if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 { tbNum = n; tbDen = d }
        }

        func flush() {
            guard var c = current else { return }
            let factor = tbNum / tbDen
            c.start = rawStart * factor
            c.end = (rawEnd ?? rawStart) * factor
            chapters.append(c)
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces) == "[CHAPTER]" {
                flush()
                current = FFChapter(); rawStart = 0; rawEnd = nil   // TIMEBASE bewusst geerbt
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
            case "START": rawStart = Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
            case "END": rawEnd = Double(value.trimmingCharacters(in: .whitespaces))
            case "TITLE": current?.title = unescapeFFMetadata(value)
            default: break
            }
        }
        flush()

        // Fehlende/ungültige END-Zeiten aus dem Start des nächsten Kapitels füllen.
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
