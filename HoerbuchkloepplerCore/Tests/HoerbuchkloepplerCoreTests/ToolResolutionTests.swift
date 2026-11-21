import Foundation
import Testing
@testable import HoerbuchkloepplerCore
import Darwin

@Suite("Werkzeugauflösung und Versionsprüfung")
struct ToolResolutionTests {
    @Test("Nicht ausführbares Bundle-Tool verdeckt PATH nicht")
    func skipsBrokenBundledCandidate() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundled = directory.appendingPathComponent("bundled-ffmpeg")
        let pathDirectory = directory.appendingPathComponent("path")
        try FileManager.default.createDirectory(at: pathDirectory, withIntermediateDirectories: true)
        let pathTool = pathDirectory.appendingPathComponent("ffmpeg")
        try "kaputt".write(to: bundled, atomically: true, encoding: .utf8)
        try writeExecutable(pathTool, "#!/bin/sh\nexit 0\n")

        let resolved = FFmpegWrapper.resolveBinaryURL(
            name: "ffmpeg",
            bundledURL: bundled,
            pathEnvironment: pathDirectory.path,
            fallbackPaths: []
        )
        #expect(resolved == pathTool)
    }

    @Test("Verzeichnisse gelten nicht als ausführbare Tools")
    func rejectsDirectory() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!FFmpegWrapper.isUsableExecutable(directory))
    }

    @Test("Symlink auf ein ausführbares Ziel gilt als brauchbares Tool (Homebrew-Fall)")
    func acceptsSymlinkToExecutable() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Nachbau des Homebrew-Layouts: bin/ffmpeg -> ../Cellar/ffmpeg/ffmpeg
        let cellar = directory.appendingPathComponent("Cellar")
        let binDirectory = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: cellar, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let target = cellar.appendingPathComponent("ffmpeg")
        try writeExecutable(target, "#!/bin/sh\nexit 0\n")
        let link = binDirectory.appendingPathComponent("ffmpeg")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "../Cellar/ffmpeg"
        )

        #expect(FFmpegWrapper.isUsableExecutable(link))
        // Die PATH-Auflösung akzeptiert den Kandidaten, friert aber das geprüfte
        // Ziel ein; eine spätere Umlenkung des Symlinks darf nichts ändern.
        let resolved = FFmpegWrapper.resolveBinaryURL(
            name: "ffmpeg",
            bundledURL: nil,
            pathEnvironment: binDirectory.path,
            fallbackPaths: []
        )
        #expect(resolved == target)
    }

    @Test("Hängender Symlink ohne Ziel bleibt unbrauchbar")
    func rejectsDanglingSymlink() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("ffmpeg")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "gibt-es-nicht"
        )

        #expect(!FFmpegWrapper.isUsableExecutable(link))
    }

    @Test("Version gilt nur bei Exit 0 und nichtleerer Ausgabe")
    func validatesVersionProcess() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appendingPathComponent("good")
        let bad = directory.appendingPathComponent("bad")
        try writeExecutable(good, "#!/bin/sh\necho 'ffmpeg version 7.1'\n")
        try writeExecutable(bad, "#!/bin/sh\necho 'ffmpeg version kaputt'\nexit 3\n")
        #expect(FFmpegWrapper.toolVersion(at: good, name: "ffmpeg") == "7.1")
        #expect(FFmpegWrapper.toolVersion(at: bad, name: "ffmpeg") == nil)
    }

    @Test("Große Versionsausgabe blockiert nicht am Pipe-Puffer")
    func drainsLargeVersionOutputBeforeWaiting() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = directory.appendingPathComponent("large-output")
        try writeExecutable(
            tool, """
            #!/bin/sh
            /usr/bin/yes x | /usr/bin/head -c 200000
            printf '\nffmpeg version 7.1\n'
            """
        )

        #expect(FFmpegWrapper.toolVersion(at: tool, name: "ffmpeg") == "7.1")
    }
}
