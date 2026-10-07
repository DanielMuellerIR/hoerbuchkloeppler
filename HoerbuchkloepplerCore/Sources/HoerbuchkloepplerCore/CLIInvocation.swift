import Foundation

/// Vollständige, shell-sicher darstellbare Übergabe der aktuellen GUI-Auswahl
/// an die ordnerbasierte CLI.
public struct CLIInvocation: Sendable {
    public let executable: String
    public let folderURL: URL
    public let arguments: [String]

    public init(
        executable: String,
        folderURL: URL,
        settings: AudioSettings,
        title: String,
        author: String,
        genre: String = "Hörbuch",
        coverPath: String? = nil,
        suppressCover: Bool = false,
        narrator: String = "", series: String = "", volumeNumber: String = "", language: String = ""
    ) {
        self.executable = executable
        self.folderURL = folderURL

        var arguments = [
            folderURL.path,
            "--mode", settings.useParallelEncoding ? "parallel" : "standard",
            "--bitrate", settings.bitrate,
            "--samplerate", String(settings.sampleRate),
            settings.isMono ? "--mono" : "--stereo"
        ]
        if settings.importWorkerLimit != 4 { arguments += ["--import-workers", String(settings.importWorkerLimit)] }
        if let limit = settings.workerLimit { arguments += ["--workers", String(limit)] }
        if let maxDurationHours = settings.maxDurationHours {
            arguments += ["--max-duration", String(maxDurationHours)]
        }
        // Freitext einheitlich in der `--option=wert`-Form und einheitlich
        // übergeben: In der getrennten Form liest der Argumentparser
        // einen Wert mit führendem Bindestrich als Option, ein Buchtitel wie
        // „-Aufzeichnungen" ließ den kopierten Befehl mit „Missing value for
        // '--title'" abbrechen. Auch leere Werte sind ausdrückliche Overrides:
        // Sonst kämen beim CLI-Reimport bewusst entfernte Tags zurück.
        let freeText = [
            ("--title", title), ("--author", author), ("--genre", genre),
            ("--narrator", narrator), ("--series", series),
            ("--volume-number", volumeNumber), ("--language", language)
        ]
        for (key, value) in freeText {
            // ArgumentParser lehnt `--option=` ab, akzeptiert aber ein eigenes
            // leeres Argument. Nur dieser Leerwert braucht die getrennte Form.
            if value.isEmpty { arguments += [key, ""] }
            else { arguments.append("\(key)=\(value)") }
        }
        if settings.analyzeLoudness { arguments.append("--analyze-loudness") }
        if settings.normalizeLoudness { arguments.append("--normalize-loudness") }
        if suppressCover {
            arguments.append("--no-cover")
        } else if let coverPath {
            arguments.append("--cover=\(coverPath)")
        }
        // Auch das ausführliche Logging reist mit — sonst verhält sich der
        // kopierte Befehl anders als die aktuelle GUI-Session.
        if settings.isVerbose {
            arguments.append("--verbose")
        }
        self.arguments = arguments
    }

    public var shellCommand: String {
        ([executable] + arguments).map(Self.shellQuote).joined(separator: " ")
    }

    /// POSIX-Shell-Quoting ohne Interpretation von `$`, Backticks oder
    /// Zeilenumbrüchen. Ein enthaltenes Apostroph wird kurz außerhalb der
    /// einfachen Anführungszeichen maskiert.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
