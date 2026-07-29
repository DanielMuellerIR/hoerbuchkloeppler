import Foundation

/// Vollständige, shell-sicher darstellbare Übergabe der aktuellen GUI-Auswahl
/// an die ordnerbasierte CLI.
public struct CLIInvocation {
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
        suppressCover: Bool = false
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
        if let maxDurationHours = settings.maxDurationHours {
            arguments += ["--max-duration", String(maxDurationHours)]
        }
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--title", title]
        }
        if !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--author", author]
        }
        if !genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--genre", genre]
        }
        if suppressCover {
            arguments.append("--no-cover")
        } else if let coverPath {
            arguments += ["--cover", coverPath]
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
