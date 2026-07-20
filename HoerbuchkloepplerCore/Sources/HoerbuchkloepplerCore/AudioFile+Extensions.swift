import Foundation
import AVFoundation

extension AudioFile {
    /// Extrahiert das eingebettete Cover aus einer Audiodatei.
    /// Nutzt sowohl Common-Keys als auch Raw-Keys für maximale Kompatibilität (MP3, M4A, etc.)
    public static func extractEmbeddedArtwork(from url: URL) -> Data? {
        print("🎨 Cover-Extraktion gestartet für: \(url.lastPathComponent)")
        let asset = AVAsset(url: url)
        
        for item in asset.metadata {
            // 1. Prüfung über CommonKey (Standardweg)
            if let commonKey = item.commonKey?.rawValue, (commonKey == "artwork" || commonKey == "cover") {
                if let data = item.value as? Data {
                    print("✅ Cover gefunden via CommonKey (\(commonKey))")
                    return data
                }
            }
            
            // 2. Prüfung über den rohen Key (oft nötig für ID3/MP3)
            if let key = item.key as? String, (key.contains("artwork") || key.contains("cover")) {
                if let data = item.value as? Data {
                    print("✅ Cover gefunden via RawKey (\(key))")
                    return data
                }
            }
        }
        print("❌ Kein eingebettetes Cover in \(url.lastPathComponent) gefunden.")
        return nil
    }

    /// Analysiert m4b/mp4 Dateien mit dem **gebündelten** `ffmpeg` und extrahiert
    /// die Kapitelstruktur. Nutzt absichtlich kein `ffprobe` — das ist NICHT
    /// mitgeliefert und fehlt auf Maschinen ohne Homebrew, wodurch m4b-Kapitel
    /// in der verteilten App verloren gingen. `ffmpeg -f ffmetadata -` schreibt
    /// die Metadaten (inkl. `[CHAPTER]`-Blöcke) nach stdout.
    public static func extractChapters(from url: URL) -> [AudioFile]? {
        guard ["m4b", "mp4"].contains(url.pathExtension.lowercased()) else { return nil }

        guard let ffmpegURL = FFmpegWrapper.getBinaryURL(name: "ffmpeg") else {
            print("⚠️ ffmpeg wurde auf diesem System nicht gefunden. Kapitel-Extraktion übersprungen.")
            return [AudioFile(url: url)]
        }

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = ["-nostdin", "-v", "quiet", "-i", url.path, "-f", "ffmetadata", "-"]

        let pipe = Pipe()
        process.standardOutput = pipe
        // stderr getrennt verwerfen, damit es die Metadaten-Ausgabe nicht stört.
        process.standardError = Pipe()

        do {
            try process.run()
            // Erst die Pipe leeren, DANN auf Exit warten — sonst Deadlock, wenn
            // die Kapitelliste den Pipe-Puffer (~64 KB) füllt.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard let text = String(data: data, encoding: .utf8) else {
                print("⚠️ FFMETADATA von \(url.lastPathComponent) nicht lesbar. Fallback auf Einzelfile.")
                return [AudioFile(url: url)]
            }
            var chapters = parseFFMetadataChapters(text)
            guard !chapters.isEmpty else {
                print("⚠️ Keine Kapitel in \(url.lastPathComponent) gefunden. Fallback auf Einzelfile.")
                return [AudioFile(url: url)]
            }

            // Das LETZTE Kapitel hat in FFMETADATA oft keine END-Zeit — es gibt kein
            // Folgekapitel, aus dem sie (wie in parseFFMetadataChapters) abgeleitet
            // werden könnte. Ohne Korrektur bliebe es ein Null-Dauer-Kapitel, das ein
            // leeres Segment erzeugt und die GANZE Konvertierung scheitern lässt.
            // Deshalb die fehlende letzte END-Zeit aus der Gesamtdauer der Datei ableiten.
            if let last = chapters.indices.last, chapters[last].end <= chapters[last].start {
                let totalDuration = CMTimeGetSeconds(AVURLAsset(url: url).duration)
                if totalDuration.isFinite, totalDuration > chapters[last].start {
                    chapters[last].end = totalDuration
                }
            }

            var audioFiles: [AudioFile] = []
            for (index, ch) in chapters.enumerated() {
                let title = ch.title.isEmpty ? "Kapitel \(index + 1)" : ch.title
                // AudioFile.init klemmt Dauer/startTime auf endlich und >= 0.
                audioFiles.append(AudioFile(
                    url: url,
                    startTime: ch.start,
                    duration: ch.end - ch.start,
                    chapterTitle: title
                ))
            }
            print("✅ \(audioFiles.count) Kapitel aus \(url.lastPathComponent) extrahiert.")
            return audioFiles
        } catch {
            print("❌ ffmpeg Fehler bei \(url.lastPathComponent): \(error)")
            return [AudioFile(url: url)]
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
            let factor = tbDen != 0 ? tbNum / tbDen : 0.001
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
