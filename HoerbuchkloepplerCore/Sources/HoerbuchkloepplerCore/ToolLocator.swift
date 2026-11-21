import Foundation

enum ToolLocator {
    /// Nur reguläre, ausführbare Dateien sind startfähige Tool-Kandidaten.
    /// Ein gebündeltes Binary ohne x-Bit darf den funktionierenden PATH-Fallback
    /// nicht verdecken. Symlinks werden vor der Prüfung aufgelöst:
    /// `attributesOfItem` folgt ihnen nicht und meldet `.typeSymbolicLink` statt
    /// `.typeRegular` — die üblichen Homebrew-/MacPorts-Symlinks (z.B.
    /// `/opt/homebrew/bin/ffmpeg` → `../Cellar/…`) fielen sonst durch.
    static func isUsableExecutable(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: resolved.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            return false
        }
        return true
    }

    static func resolveBinaryURL(name: String, bundledURL: URL?, pathEnvironment: String?, fallbackPaths: [String]) -> URL? {
        var candidates: [URL] = []
        if let bundledURL { candidates.append(bundledURL) }
        if let pathEnvironment {
            candidates += pathEnvironment.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent(name)
            }
        }
        candidates += fallbackPaths.map { URL(fileURLWithPath: $0) }
        for candidate in candidates where isUsableExecutable(candidate) {
            // Nicht den später veränderbaren Symlink starten, sondern genau das
            // reguläre Binary, das `isUsableExecutable` geprüft hat.
            return candidate.resolvingSymlinksInPath()
        }
        return nil
    }

    static func binaryURL(name: String) -> URL? {
        let bundledURL = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "bin")
        let fallbackPaths = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/opt/local/bin/\(name)", "/usr/bin/\(name)", "/bin/\(name)"]
        return resolveBinaryURL(
            name: name,
            bundledURL: bundledURL,
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"],
            fallbackPaths: fallbackPaths
        )
    }

    /// Liefert nur dann eine Version, wenn der Prozess wirklich startet,
    /// erfolgreich endet und eine nichtleere Ausgabe liefert.
    static func toolVersion(name: String) -> (url: URL, version: String)? {
        guard let url = binaryURL(name: name), let version = toolVersion(at: url, name: name) else { return nil }
        return (url, version)
    }

    static func toolVersion(at url: URL, name: String) -> String? {
        guard isUsableExecutable(url) else { return nil }
        // Ein vorübergehend fehlgeschlagener erster Start soll ein vorhandenes
        // Werkzeug nicht für die ganze App-Sitzung als fehlend markieren.
        return probeVersion(at: url, name: name) ?? probeVersion(at: url, name: name)
    }

    private static func probeVersion(at url: URL, name: String) -> String? {
        let result = ProcessRunner.capture(
            executableURL: url,
            // Auch der kurze Versionsaufruf erfüllt den repo-weiten
            // ffmpeg-Vertrag mit `-nostdin`. `ProcessRunner.capture` trennt stdin
            // zusätzlich vom Terminal, damit beide Schutzschichten unabhängig
            // von künftigen Aufrufwegen erhalten bleiben.
            arguments: name == "mediainfo" ? ["--Version"] : ["-nostdin", "-version"],
            timeout: 5
        )
        guard case .completed(let status, let data) = result,
              status == 0,
              let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { return nil }
        let parts = output.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        if let index = parts.firstIndex(where: { $0.lowercased() == "version" }),
           index + 1 < parts.count {
            return parts[index + 1].replacingOccurrences(of: ",", with: "")
        }
        if name == "mediainfo",
           let version = parts.first(where: { $0.hasPrefix("v") && $0.contains(".") }) {
            return version
        }
        return parts.first
    }
}

extension FFmpegWrapper {
    public static func isUsableExecutable(_ url: URL) -> Bool {
        ToolLocator.isUsableExecutable(url)
    }

    public static func getBinaryURL(name: String) -> URL? {
        ToolLocator.binaryURL(name: name)
    }

    public static func toolVersion(name: String) -> (url: URL, version: String)? {
        ToolLocator.toolVersion(name: name)
    }
}
