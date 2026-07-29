import Foundation
import AppKit
import ArgumentParser
import HoerbuchkloepplerCore
import Darwin

private func writeStandardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private final class InterruptState: @unchecked Sendable {
    private enum Phase {
        case preparing
        case converting
        case finished
    }

    private let lock = NSLock()
    private var received = false
    private var phase: Phase = .preparing

    var shouldCancelPreparation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return phase == .preparing
    }

    /// Akzeptiert das Signal nur, solange noch Arbeit abgebrochen werden kann.
    /// Ein vom Core nach dem letzten atomaren Commit abgelehnter Cancel darf
    /// keinen falschen Exit 130 mehr erzeugen.
    func recordSignal(
        conversionOutcome: ConversionCancellationOutcome,
        preparationCancelled: Bool
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase != .finished else { return false }
        switch conversionOutcome {
        case .cancelled:
            received = true
        case .noActiveConversion:
            // In der Vorbereitung oder in der winzigen Lücke direkt vor dem
            // synchronen Anlegen des Conversion-Contexts bleibt das Signal offen.
            received = true
        case .rejected:
            if phase == .preparing, preparationCancelled { received = true }
        }
        return received
    }

    func beginConversion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !received else { return false }
        phase = .converting
        return true
    }

    func finishConversion() {
        lock.lock()
        phase = .finished
        lock.unlock()
    }

    var wasReceived: Bool {
        lock.lock()
        defer { lock.unlock() }
        return received
    }
}

private func readLine(unlessInterrupted state: InterruptState) -> String? {
    var descriptor = pollfd(
        fd: FileHandle.standardInput.fileDescriptor,
        events: Int16(POLLIN),
        revents: 0
    )
    while !state.wasReceived {
        let result = Darwin.poll(&descriptor, 1, 100)
        if result > 0 { return Swift.readLine() }
        if result < 0, errno != EINTR { return nil }
    }
    return nil
}

/// Sendable-Snapshot der von ArgumentParser gefüllten Optionen. Die Parser-
/// Konformität bleibt dadurch nichtisoliert; nur die eigentliche Ausführung
/// wechselt anschließend auf den Main Actor.
private struct CLIOptions: Sendable {
    let folderPath: String
    let mode: String?
    let bitrate: String?
    let samplerate: Int?
    let maxDuration: Int?
    let title: String?
    let author: String?
    let genre: String?
    let cover: String?
    let noCover: Bool
    let mono: Bool
    let stereo: Bool
    let output: String?
    let verbose: Bool
    let force: Bool
}

/// Hält den Pacman-Statusblock am unteren Rand des Terminals und trennt ihn
/// sauber von den Logzeilen.
///
/// Das Problem ohne diese Klasse: Der Statusblock wird per ANSI-Cursor-Sprüngen
/// überschrieben, dafür muss die Zeilenzahl des zuletzt gezeichneten Blocks
/// stimmen. Schreibt zwischendurch jemand anders eine Logzeile, verschiebt sich
/// alles und der Cursor löscht die falschen Zeilen — das Terminalbild zerfällt.
///
/// Lösung: Alle Ausgaben laufen durch diesen Renderer. Vor jeder Logzeile wird
/// der Block entfernt, die Zeile bleibt dauerhaft stehen, und die Schleife
/// zeichnet den Block danach darunter neu.
///
/// Nicht thread-sicher — sämtliche Aufrufe kommen vom Main-Thread (die Log-Senke
/// der Session stellt das sicher).
@MainActor
final class TerminalRenderer {
    /// Zeilenzahl des aktuell sichtbaren Statusblocks; 0 = kein Block auf dem Schirm.
    private var blockLines = 0
    private var lastPlainStatus = ""
    private let usesANSI: Bool

    init(outputFileDescriptor: Int32 = FileHandle.standardOutput.fileDescriptor) {
        usesANSI = isatty(outputFileDescriptor) != 0
    }

    /// Entfernt den Statusblock vom Bildschirm. Danach steht der Cursor wieder
    /// dort, wo der Block begann.
    func clearBlock() {
        guard usesANSI else { return }
        guard blockLines > 0 else { return }
        // Je Blockzeile: eine Zeile hoch (1A) und diese löschen (2K); zum Schluss
        // an den Zeilenanfang (G).
        print(String(repeating: "\u{001B}[1A\u{001B}[2K", count: blockLines), terminator: "\u{001B}[G")
        blockLines = 0
    }

    /// Schreibt eine dauerhafte Logzeile oberhalb des Statusblocks.
    func emitLog(_ line: String) {
        if usesANSI { clearBlock() }
        print(line)
    }

    /// Zeichnet den Statusblock neu. `text` muss jede Zeile mit "\n" abschließen.
    func drawBlock(_ text: String) {
        guard usesANSI else {
            // In Pipes/CI weder Escape-Sequenzen noch 10 Statusblöcke pro
            // Sekunde ausgeben. Nur echte Statuswechsel bleiben als Klartext.
            let status = text.split(separator: "\n", maxSplits: 1)
                .first
                .map(String.init) ?? ""
            if !status.isEmpty, status != lastPlainStatus {
                print(status)
                lastPlainStatus = status
            }
            return
        }
        clearBlock()
        print(text, terminator: "")
        blockLines = text.filter { $0 == "\n" }.count
    }
}

@main
struct KloepplerCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kloeppler",
        abstract: "Ein Kommandozeilen-Tool zum Generieren von M4B Hörbüchern aus Audiodateien."
    )
    
    @Argument(help: "Der absolute Pfad zum Ordner, der die Audiodateien enthält.")
    var folderPath: String
    
    @Option(name: .shortAndLong, help: "Der Kodierungsmodus: 'parallel' (Performance) oder 'standard' (Sequenziell).")
    var mode: String?
    
    @Option(name: .long, help: "Die Ziel-Bitrate, z.B. '48k' oder '64k'.")
    var bitrate: String?
    
    @Option(name: .long, help: "Die Abtastrate (Sample Rate) in Hz, z.B. 48000.")
    var samplerate: Int?

    @Option(name: .long, help: "Maximale Dauer pro Ausgabedatei in Stunden. Längere Bücher werden auf -01, -02 ... aufgeteilt (0 = unbegrenzt).")
    var maxDuration: Int?
    
    @Option(name: .long, help: "Setzt den Buchtitel explizit (überschreibt die aus den Tags erkannten Kandidaten). Wird auch für den Ausgabe-Dateinamen verwendet.")
    var title: String?

    @Option(name: .long, help: "Setzt den Autor explizit (überschreibt die aus den Tags erkannten Kandidaten, z.B. wenn dort Übersetzer mit drinstehen).")
    var author: String?

    @Option(name: .long, help: "Setzt das Genre explizit.")
    var genre: String?

    @Option(name: .long, help: "Verwendet die angegebene Bilddatei als Cover.")
    var cover: String?

    @Flag(name: .long, help: "Erzeugt das Hörbuch ohne Cover, auch wenn die Quelle eines enthält.")
    var noCover: Bool = false

    @Flag(name: .long, help: "Kodiert das Hörbuch in Mono.")
    var mono: Bool = false
    
    @Flag(name: .long, help: "Kodiert das Hörbuch in Stereo.")
    var stereo: Bool = false
    
    @Option(name: [.short, .long], help: "Ausgabeziel: Ordner (Datei heißt dann <Titel>.m4b) oder vollständiger .m4b-Pfad. Ohne Angabe landet die Datei wie bisher im Eltern-Ordner der Quelle — bei Quellen auf vollen/schreibgeschützten Datenträgern ist --output nötig.")
    var output: String?

    @Flag(name: .shortAndLong, help: "Aktiviert ausführliches Logging aller Pfade und Vorgänge.")
    var verbose: Bool = false
    
    @Flag(name: .shortAndLong, help: "Überschreibt die Ausgabedatei ohne Nachfrage.")
    var force: Bool = false

    // Eingaben früh prüfen (läuft vor run()), damit klare Fehler entstehen statt
    // erst später eine kryptische ffmpeg-Meldung — wichtig für den Skript-/Agent-Einsatz.
    func validate() throws {
        if let mode = mode, !["parallel", "standard"].contains(mode.lowercased()) {
            throw ValidationError("Ungültiger --mode '\(mode)'. Erlaubt: 'parallel' oder 'standard'.")
        }
        if let bitrate = bitrate, !AudioSettings.isValidBitrate(bitrate) {
            throw ValidationError("Ungültige --bitrate '\(bitrate)'. Erwartet wird eine positive Zahl mit optionalem 'k', z.B. '48k' oder '64000'.")
        }
        if let samplerate = samplerate, !(8000...192000).contains(samplerate) {
            throw ValidationError("Ungültige --samplerate \(samplerate). Erlaubt: 8000–192000 Hz (z.B. 32000, 44100, 48000).")
        }
        if let maxDuration, maxDuration < 0 {
            throw ValidationError("Ungültige --max-duration \(maxDuration). Erlaubt: 0 (unbegrenzt) oder eine positive Stundenzahl.")
        }
        if mono && stereo {
            throw ValidationError("--mono und --stereo schließen sich gegenseitig aus.")
        }
        if cover != nil && noCover {
            throw ValidationError("--cover und --no-cover schließen sich gegenseitig aus.")
        }
    }

    mutating func run() async throws {
        let options = CLIOptions(
            folderPath: folderPath,
            mode: mode,
            bitrate: bitrate,
            samplerate: samplerate,
            maxDuration: maxDuration,
            title: title,
            author: author,
            genre: genre,
            cover: cover,
            noCover: noCover,
            mono: mono,
            stereo: stereo,
            output: output,
            verbose: verbose,
            force: force
        )
        try await Self.execute(options)
    }

    @MainActor
    private static func execute(_ options: CLIOptions) async throws {
        let folderPath = options.folderPath
        let mode = options.mode
        let bitrate = options.bitrate
        let samplerate = options.samplerate
        let maxDuration = options.maxDuration
        let title = options.title
        let author = options.author
        let genre = options.genre
        let cover = options.cover
        let noCover = options.noCover
        let mono = options.mono
        let stereo = options.stereo
        let output = options.output
        let verbose = options.verbose
        let force = options.force

        let url = URL(fileURLWithPath: folderPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else {
            writeStandardError("Fehler: Der Pfad \(folderPath) existiert nicht oder ist kein Ordner.")
            throw ExitCode.failure
        }
        
        FFmpegWrapper.cleanupOldTempDirectories()
        // CLI-Aufrufe sind reproduzierbar: nicht gesetzte Optionen verwenden die
        // dokumentierten Defaults und hängen nicht von GUI-settings.json ab.
        let session = ConversionSession(settings: AudioSettings())

        // Ab hier gehört das Terminal dem Renderer: Alle Session-Logs laufen über
        // ihn, damit sie nicht in die Pacman-Fortschrittsanzeige hineinschreiben.
        let renderer = TerminalRenderer()
        session.logSink = { renderer.emitLog($0) }

        // Setup SIGINT handler
        let interruptState = InterruptState()
        let signalQueue = DispatchQueue(label: "de.hoerbuchkloeppler.sigint")
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        sigintSource.setEventHandler {
            let preparationCancelled = interruptState.shouldCancelPreparation
                ? session.cancelPreparation()
                : false
            let outcome = FFmpegWrapper.cancelConversion(session: session)
            if interruptState.recordSignal(
                conversionOutcome: outcome,
                preparationCancelled: preparationCancelled
            ) {
                Task { @MainActor in
                    renderer.emitLog("🛑 Abbruchsignal (SIGINT) empfangen. Bereinige und beende...")
                }
            }
        }
        signal(SIGINT, SIG_IGN)
        sigintSource.resume()
        defer { sigintSource.cancel() }

        session.beginPreparation()
        if interruptState.wasReceived {
            session.cancelPreparation()
            throw ExitCode(130)
        }
        await session.addFolder(url)

        if interruptState.wasReceived { throw ExitCode(130) }

        guard !session.audioFiles.isEmpty else {
            writeStandardError("Fehler: Keine gültigen Audiodateien im Ordner gefunden.")
            throw ExitCode.failure
        }
        
        if let mode = mode {
            session.settings.useParallelEncoding = (mode.lowercased() == "parallel")
        }
        if let bitrate = bitrate { session.settings.bitrate = bitrate }
        if let samplerate = samplerate { session.settings.sampleRate = samplerate }
        if let maxDuration = maxDuration { session.settings.maxDurationHours = maxDuration > 0 ? maxDuration : nil }
        if mono { session.settings.isMono = true }
        else if stereo { session.settings.isMono = false }
        if verbose { session.settings.isVerbose = true }

        // Explizite CLI-Angaben gewinnen IMMER gegen die aus den Datei-Tags
        // erkannten Kandidaten (die enthalten z.B. oft Übersetzer im Autor-Feld).
        // Muss NACH dem vollständig erwarteten `addFolder` passieren, sonst
        // würde der Metadaten-Fetch die Werte wieder überschreiben.
        if let title = title { session.title = title }
        if let author = author { session.author = author }
        if let genre = genre { session.genre = genre }
        if noCover {
            session.removeCover()
        } else if let cover {
            let coverURL = URL(fileURLWithPath: cover)
            guard session.selectCover(url: coverURL) else {
                writeStandardError("❌ Cover-Datei ist nicht als Bild lesbar: \(cover)")
                throw ExitCode.failure
            }
        }
        if interruptState.wasReceived { throw ExitCode(130) }

        let rawTitle = session.title.isEmpty ? url.lastPathComponent : session.title
        let finalTitle = KloepplerCLI.sanitizeFilename(rawTitle)
        let outputFile: URL
        if let output = output {
            var outIsDir: ObjCBool = false
            let outExists = FileManager.default.fileExists(atPath: output, isDirectory: &outIsDir)
            if outExists && outIsDir.boolValue {
                // Ordner angegeben: Dateiname wie bisher aus dem Titel bilden
                outputFile = URL(fileURLWithPath: output).appendingPathComponent("\(finalTitle).m4b")
            } else if output.lowercased().hasSuffix(".m4b") {
                // Voller Zielpfad: Eltern-Ordner muss existieren (bei Bedarf anlegen)
                let target = URL(fileURLWithPath: output)
                do {
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                } catch {
                    writeStandardError("❌ Ausgabeordner konnte nicht angelegt werden: \(error.localizedDescription)")
                    throw ExitCode.failure
                }
                outputFile = target
            } else {
                writeStandardError("❌ --output muss ein existierender Ordner oder ein .m4b-Pfad sein: \(output)")
                throw ExitCode.failure
            }
        } else {
            outputFile = url.deletingLastPathComponent().appendingPathComponent("\(finalTitle).m4b")
        }
        
        print("Starte Konvertierung...")
        let conversionPlan = FFmpegWrapper.makeConversionPlan(
            files: session.audioFiles,
            outputURL: outputFile,
            maxDurationHours: session.settings.maxDurationHours
        )
        print(conversionPlan.outputURLs.count == 1 ? "Zieldatei:" : "Zieldateien:")
        conversionPlan.outputURLs.forEach { print("  \($0.path)") }

        let existingOutputs = conversionPlan.outputURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existingOutputs.isEmpty {
            let names = existingOutputs.map(\.lastPathComponent).joined(separator: ", ")
            if force {
                print("⚠️ Vorhandene Zieldatei(en) werden überschrieben (--force): \(names)")
            } else if isatty(FileHandle.standardInput.fileDescriptor) == 0 {
                // Nicht-interaktiv (Pipe/CI/AI-Agent): nicht blockierend nachfragen,
                // sondern klar mit Fehlercode abbrechen und auf --force hinweisen.
                writeStandardError("❌ Zieldatei(en) existieren bereits: \(names). Zum Überschreiben --force verwenden.")
                throw ExitCode.failure
            } else {
                print("⚠️ Diese Zieldatei(en) existieren bereits: \(names)")
                print("Möchten Sie die Dateien überschreiben? (j/N): ", terminator: "")
                if let input = readLine(unlessInterrupted: interruptState),
                   input.lowercased() == "j" || input.lowercased() == "y" {
                    print("Datei wird überschrieben...")
                } else if interruptState.wasReceived {
                    throw ExitCode(130)
                } else {
                    print("Vorgang abgebrochen.")
                    throw ExitCode(2)
                }
            }
        }

        guard interruptState.beginConversion() else { throw ExitCode(130) }
        FFmpegWrapper.convert(session: session, plan: conversionPlan)
        // Ein Signal kann genau zwischen Phasenwechsel und dem synchronen
        // Erzeugen des Contexts eintreffen. Dann jetzt den neuen Context stoppen.
        if interruptState.wasReceived {
            _ = FFmpegWrapper.cancelConversion(session: session)
        }

        // Print ASCII Art Cover if verbose
        if verbose, let coverPath = session.coverPath, let img = NSImage(contentsOfFile: coverPath) {
            print("\n--- Cover ASCII Art ---")
            print(KloepplerCLI.generateAsciiArt(from: img, width: 40))
            print("-----------------------\n")
        }

        // Asynchron warten, damit der Main Actor die Fortschrittsmeldungen des
        // ffmpeg-Workers übernehmen kann.
        // Abbruchbedingung ist das definitive Abschluss-Signal lastConversionSucceeded
        // (vom Core genau einmal am Ende gesetzt). NICHT auf das transiente
        // isConverting==true warten -- bei sehr schnell abschließenden Läufen
        // (z.B. sofortiger Fehler) könnte die Schleife den kurzen Zustand sonst
        // vollständig verpassen.
        while session.lastConversionSucceeded == nil {
            try await Task.sleep(for: .milliseconds(100))

            var output = ""
            let currentStatus = session.conversionStatus
            output += "Status: \(currentStatus)\n"

            // Draw Pacmans
            let sortedKeys = session.segmentProgress.keys.sorted()
            for key in sortedKeys {
                if let status = session.segmentProgress[key] {
                    let pacmanStr = KloepplerCLI.buildPacmanBar(progress: status.progress, width: 20)
                    let keyStr = String(format: "%03d", key)
                    let fileStr = status.filename.prefix(25).padding(toLength: 25, withPad: " ", startingAt: 0)
                    let percentStr = String(format: "%3d%%", Int(status.progress * 100))
                    output += "\(keyStr) \(fileStr) | \(pacmanStr) | \(percentStr)\n"
                }
            }

            renderer.drawBlock(output)
        }

        // Fortschrittsanzeige abräumen — die Schlussmeldung soll allein stehen.
        renderer.clearBlock()

        // Exit 130 erst NACH dem definitiven Worker-Abschluss. So sind Prozesse,
        // Temp-Verzeichnisse und große .partial-Dateien sicher bereinigt.
        let wasInterrupted = interruptState.wasReceived
        interruptState.finishConversion()
        if wasInterrupted { throw ExitCode(130) }

        // Ehrlicher Abschluss: nur bei echtem Erfolg Exit 0, sonst Fehler-Exit
        // (wichtig für Skripte/AI-Agenten, die den Exit-Code auswerten).
        if session.lastConversionSucceeded == true {
            print(conversionPlan.outputURLs.count == 1 ? "🎉 Vorgang beendet. Datei:" : "🎉 Vorgang beendet. Dateien:")
            conversionPlan.outputURLs.forEach { print("  \($0.path)") }
        } else {
            let completedOutputs = session.completedOutputURLs
            if completedOutputs.isEmpty {
                writeStandardError("❌ Vorgang fehlgeschlagen. Es wurde keine gültige Datei erzeugt.")
            } else {
                writeStandardError("❌ Vorgang unvollständig. Erfolgreich erzeugte Datei(en):")
                completedOutputs.forEach { writeStandardError("  \($0.path)") }
            }
            throw ExitCode.failure
        }
    }
    
    /// Macht aus einem (Metadaten-)Titel einen sicheren Dateinamen: Pfad- und
    /// Steuerzeichen (`/`, `:`, `\`, Umbrüche) werden durch `-` ersetzt, Rand-
    /// Whitespace/Punkte entfernt. Sonst landete der Output bei einem Titel mit
    /// `/` im falschen Verzeichnis oder der Schreibvorgang schlug fehl.
    static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\\n\r\t").union(.controlCharacters)
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .").union(.whitespacesAndNewlines))
        return cleaned.isEmpty ? "Hoerbuch" : cleaned
    }

    static func buildPacmanBar(progress: Double, width: Int) -> String {
        let filledCount = Int(progress * Double(width))
        let emptyCount = max(0, width - filledCount - 1)
        
        if progress >= 1.0 {
            return String(repeating: " ", count: width) + "ᗧ"
        }
        
        let spaces = String(repeating: " ", count: filledCount)
        let dots = String(repeating: "•", count: emptyCount)
        let mouthOpen = Int(Date().timeIntervalSince1970 * 5) % 2 == 0
        let pacman = mouthOpen ? "ᗧ" : "○"
        
        return spaces + pacman + dots
    }
    
    static func generateAsciiArt(from image: NSImage, width: Int) -> String {
        // Simple ASCII mapping from dark to light
        let asciiChars = ["@", "%", "#", "*", "+", "=", "-", ":", ".", " "]

        // Ungültige Maße abfangen: Bei width == 0 ergäbe das Seitenverhältnis
        // unten NaN/Infinity, und Int(NaN) crasht zur Laufzeit.
        guard image.size.width > 0, image.size.height > 0, width > 0 else { return "" }

        var rect = NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return "" }
        
        // Calculate height to maintain aspect ratio (terminal characters are roughly 2x as tall as they are wide)
        let aspectRatio = image.size.height / image.size.width
        let height = Int(Double(width) * aspectRatio * 0.5)
        
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bytesPerPixel = 1
        let bytesPerRow = bytesPerPixel * width
        
        var pixelData = [UInt8](repeating: 0, count: width * height)
        
        guard let context = CGContext(data: &pixelData,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return "" }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var result = ""
        for y in 0..<height {
            for x in 0..<width {
                let offset = (height - 1 - y) * width + x // CGContext draws inverted on macOS
                let pixelValue = pixelData[offset]
                // Map 0-255 to 0-9
                let charIndex = Int(Double(pixelValue) / 255.0 * Double(asciiChars.count - 1))
                result += asciiChars[charIndex]
            }
            result += "\n"
        }
        return result
    }
}
