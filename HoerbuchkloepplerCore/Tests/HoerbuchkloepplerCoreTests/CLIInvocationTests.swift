import Foundation
import Testing
@testable import HoerbuchkloepplerCore

@Suite("CLI-Übergabe aus der App")
@MainActor
struct CLIInvocationTests {
    @Test("CLI-Handoff wird nach nicht darstellbarer Kapiteledition deaktiviert")
    func cliRepresentabilityTracksChapterEdits() async {
        let session = ConversionSession()
        session.title = "Buch"
        session.author = "Autor"
        let source = URL(fileURLWithPath: "/tmp/buch")
        let file = AudioFile(
            url: source.appendingPathComponent("01.mp3"),
            startTime: 0,
            duration: 1,
            chapterTitle: "Kapitel 1"
        )
        await session.applyScannedFolder(.init(
            folderURL: source,
            audioFiles: [file],
            imageURLs: [],
            embeddedArtwork: nil
        ))
        #expect(session.cliFolderIfRepresentable == source)

        session.audioFiles[0].chapterTitle = "Manuell geändert"
        #expect(session.cliFolderIfRepresentable == nil)
    }

    @Test("CLI-Befehl enthält alle GUI-Optionen und quotet Shell-Metazeichen")
    func completeShellSafeCLICommand() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("kloeppler tool's")
        try writeExecutable(executable, """
        #!/bin/sh
        for argument in "$@"; do
            printf '%s\\000' "$argument"
        done
        """)

        var settings = AudioSettings()
        settings.useParallelEncoding = false
        settings.bitrate = "64k"
        settings.sampleRate = 44_100
        settings.maxDurationHours = 9
        settings.isMono = false
        settings.isVerbose = true
        let invocation = CLIInvocation(
            executable: executable.path,
            folderURL: URL(fileURLWithPath: "/tmp/Buch $HOME's"),
            settings: settings,
            title: "-Aufzeichnungen `printf nicht-ausführen`",
            author: "O'Brien",
            genre: "Roman & Lesung",
            coverPath: "/tmp/Cover Bild.jpg"
        )

        #expect(invocation.arguments.contains("--max-duration"))
        // Freitext in der `--option=wert`-Form: In der getrennten Form liest der
        // Argumentparser einen Wert mit führendem Bindestrich als Option, und
        // der kopierte Befehl bräche mit „Missing value for '--title'" ab.
        #expect(invocation.arguments.contains("--title=-Aufzeichnungen `printf nicht-ausführen`"))
        #expect(invocation.arguments.contains("--author=O'Brien"))
        #expect(invocation.arguments.contains("--genre=Roman & Lesung"))
        #expect(invocation.arguments.contains("--cover=/tmp/Cover Bild.jpg"))
        #expect(invocation.arguments.contains("--stereo"))
        #expect(invocation.arguments.contains("--verbose"))
        // Auch leere Overrides müssen den Reimport alter Tags überstimmen.
        let blank = CLIInvocation(
            executable: "kloeppler",
            folderURL: URL(fileURLWithPath: "/tmp"),
            settings: AudioSettings(),
            title: "",
            author: "",
            narrator: "  ",
            series: "  "
        )
        for option in ["--title", "--author", "--volume-number", "--language"] {
            let index = try #require(blank.arguments.firstIndex(of: option))
            #expect(blank.arguments[index + 1] == "")
        }
        #expect(blank.arguments.contains("--narrator=  "))
        #expect(blank.arguments.contains("--series=  "))

        // Der echte Shell-Durchlauf prüft das beobachtbare Verhalten: Weder
        // Dollarzeichen noch Backticks, Apostrophe oder Leerzeichen dürfen die
        // Argumentgrenzen oder Inhalte verändern.
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", invocation.shellCommand]
        process.standardOutput = outputPipe
        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let receivedArguments = output.split(separator: 0, omittingEmptySubsequences: false).dropLast().map {
            String(decoding: $0, as: UTF8.self)
        }

        #expect(process.terminationStatus == 0)
        #expect(receivedArguments == invocation.arguments)
    }

    @Test("CLI-Handoff kann ein automatisch gefundenes Cover bewusst unterdrücken")
    func cliInvocationCanSuppressCover() {
        let invocation = CLIInvocation(
            executable: "kloeppler",
            folderURL: URL(fileURLWithPath: "/tmp/Buch"),
            settings: AudioSettings(),
            title: "Buch",
            author: "Autor",
            coverPath: "/tmp/Cover.jpg",
            suppressCover: true
        )

        #expect(invocation.arguments.contains("--no-cover"))
        // Mit einem Cover-Pfad UND `suppressCover` konstruiert: Sonst könnte der
        // Zweig, der `--cover=…` anhängt, gar nicht feuern, und die Zusicherung
        // wäre wertlos. `hasPrefix`, weil der Wert an der Option klebt.
        #expect(!invocation.arguments.contains { $0.hasPrefix("--cover") })
        // Default-Settings haben isVerbose == false — dann auch kein --verbose.
        #expect(!invocation.arguments.contains("--verbose"))
    }
}
