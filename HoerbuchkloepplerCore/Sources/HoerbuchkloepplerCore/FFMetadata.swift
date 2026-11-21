import Foundation

enum FFMetadata {
    /// Kapitel beginnen am gerundeten Ende des jeweiligen Vorgängers.
    static func encodeChapters(group: [AudioFile]) -> String {
        var metaContent = ";FFMETADATA1\n"
        var currentTime: TimeInterval = 0
        for file in group {
            metaContent += "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(Int(currentTime * 1000))\nEND=\(Int((currentTime + file.duration) * 1000))\ntitle=\(escape(file.chapterTitle))\n"
            currentTime += file.duration
        }
        return metaContent
    }

    /// Maskiert einen Wert fürs FFMETADATA-Format. `\`, `=`, `;` und `#` werden
    /// mit Backslash escaped; Zeilenumbrüche werden zu Leerzeichen (ein
    /// Kapiteltitel ist einzeilig). Ohne das zerstört z.B. ein Newline im
    /// Kapiteltitel die gesamte chapters.txt.
    ///
    /// Sonderfall Backslash am Zeilenende: ffmpegs FFMETADATA-Leser behandelt
    /// JEDEN Backslash am Zeilenende als Zeilenfortsetzung — auch den per `\\`
    /// maskierten — und würde die folgende `[CHAPTER]`-Zeile verschlucken (ein
    /// Kapitel ginge verloren). Ein FFMETADATA-Wert darf also nicht auf einen
    /// Backslash enden; abschließende Backslashes werden daher entfernt
    /// (ffmpeg kann sie ohnehin nicht verlustfrei zurücklesen).
    static func escape(_ value: String) -> String {
        var out = ""
        for ch in value {
            switch ch {
            case "\\", "=", ";", "#":
                out.append("\\")
                out.append(ch)
            case "\n", "\r", "\r\n":
                out.append(" ")
            default:
                out.append(ch)
            }
        }
        while out.hasSuffix("\\") { out.removeLast() }
        return out
    }

    /// Ein aus FFMETADATA gelesenes Kapitel (Zeiten bereits in Sekunden).
    struct Chapter: Sendable {
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var title = ""
        var isEndMissing = false
    }

    /// Parst die `[CHAPTER]`-Blöcke aus einer FFMETADATA-Ausgabe.
    /// ffmpeg schreibt TIMEBASE in jeden Block (Default 1/1000); zur Robustheit
    /// gegen ungewöhnliche/handgepflegte Dateien wird die TIMEBASE NICHT pro
    /// Kapitel hart zurückgesetzt, sondern vom Header bzw. vorherigen Kapitel
    /// geerbt. Fehlende END-Zeiten werden aus dem Start des Folgekapitels
    /// abgeleitet (sonst entstünde ein stilles Null-Dauer-Kapitel).
    static func decodeChapters(_ text: String) -> [Chapter] {
        var chapters: [Chapter] = []
        var current: Chapter?
        var tbNum: Double = 1, tbDen: Double = 1000
        var rawStart: Double?
        var rawEnd: Double?
        var sawEnd = false

        func parseTimebase(_ value: String) {
            let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/")
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
            c.isEndMissing = !sawEnd
            chapters.append(c)
        }

        for line in logicalLines(text) {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "[CHAPTER]" {
                flush()
                current = Chapter()
                rawStart = nil
                rawEnd = nil
                sawEnd = false   // TIMEBASE bewusst geerbt
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let value = String(line[line.index(after: eq)...])
            // Vor dem ersten [CHAPTER]: nur ein evtl. globales TIMEBASE übernehmen.
            if current == nil {
                if key == "TIMEBASE" { parseTimebase(value) }
                continue
            }
            switch key {
            case "TIMEBASE": parseTimebase(value)
            case "START": rawStart = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
            case "END":
                sawEnd = true
                rawEnd = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
            case "TITLE":
                current?.title = unescape(
                    value.trimmingCharacters(in: .newlines)
                )
            default: break
            }
        }
        flush()

        for index in chapters.indices.dropLast() where chapters[index].isEndMissing {
            chapters[index].end = chapters[index + 1].start
            chapters[index].isEndMissing = false
        }
        return chapters
    }

    static func normalizedChapters(
        _ decoded: [Chapter],
        totalDuration: TimeInterval
    ) -> [Chapter]? {
        guard let lastIndex = decoded.indices.last else { return nil }
        var chapters = decoded
        // Nur ein ausgelassenes END lässt sich aus der Dateidauer ableiten.
        if chapters[lastIndex].isEndMissing {
            chapters[lastIndex].end = totalDuration
            chapters[lastIndex].isEndMissing = false
        }
        guard chaptersAreValid(chapters, totalDuration: totalDuration) else { return nil }

        // Container-Rundung ausgleichen und an die tatsächliche Dateidauer anlegen.
        chapters[0].start = 0
        for index in chapters.indices.dropFirst() {
            chapters[index].start = chapters[index - 1].end
        }
        chapters[lastIndex].end = totalDuration
        return chapters
    }

    /// Zerlegt FFMETADATA in Zeilen und hält dabei Fortsetzungszeilen zusammen.
    /// ffmpeg escapt einen Zeilenumbruch im Wert als Backslash plus echten
    /// Umbruch. Ohne dieses Zusammenfügen bräche ein Kapiteltitel dort ab, und
    /// seine Fortsetzung würde als eigenes Schlüssel/Wert-Paar gelesen — ein
    /// Titel wie „Vorwort\nEND=180000" überschriebe damit das echte Kapitelende.
    static func logicalLines(_ text: String) -> [String] {
        var lines: [String] = []
        for piece in text.components(separatedBy: "\n") {
            if let last = lines.last, endsWithEscapingBackslash(last) {
                lines[lines.count - 1].append("\n")
                lines[lines.count - 1].append(contentsOf: piece)
            } else {
                lines.append(piece)
            }
        }
        return lines
    }

    /// Ein Backslash escapt nur, wenn er selbst nicht escapt ist — deshalb zählt
    /// die ungerade Anzahl am Zeilenende.
    private static func endsWithEscapingBackslash(_ line: String) -> Bool {
        var count = 0
        for character in line.reversed() {
            if character == "\\" { count += 1 } else { break }
        }
        return count % 2 == 1
    }

    static func chaptersAreValid(
        _ chapters: [Chapter],
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
    static func unescape(_ s: String) -> String {
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
