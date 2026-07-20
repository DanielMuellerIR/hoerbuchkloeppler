import Foundation
import AppKit
import ArgumentParser
import HoerbuchkloepplerCore

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
final class TerminalRenderer {
    /// Zeilenzahl des aktuell sichtbaren Statusblocks; 0 = kein Block auf dem Schirm.
    private var blockLines = 0

    /// Entfernt den Statusblock vom Bildschirm. Danach steht der Cursor wieder
    /// dort, wo der Block begann.
    func clearBlock() {
        guard blockLines > 0 else { return }
        // Je Blockzeile: eine Zeile hoch (1A) und diese löschen (2K); zum Schluss
        // an den Zeilenanfang (G).
        print(String(repeating: "\u{001B}[1A\u{001B}[2K", count: blockLines), terminator: "\u{001B}[G")
        blockLines = 0
    }

    /// Schreibt eine dauerhafte Logzeile oberhalb des Statusblocks.
    func emitLog(_ line: String) {
        clearBlock()
        print(line)
    }

    /// Zeichnet den Statusblock neu. `text` muss jede Zeile mit "\n" abschließen.
    func drawBlock(_ text: String) {
        clearBlock()
        print(text, terminator: "")
        blockLines = text.filter { $0 == "\n" }.count
    }
}

@main
struct KloepplerCLI: ParsableCommand {
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
        if let bitrate = bitrate, bitrate.range(of: "^[0-9]+k?$", options: .regularExpression) == nil {
            throw ValidationError("Ungültige --bitrate '\(bitrate)'. Format: Zahl mit optionalem 'k', z.B. '48k' oder '64000'.")
        }
        if let samplerate = samplerate, !(8000...192000).contains(samplerate) {
            throw ValidationError("Ungültige --samplerate \(samplerate). Erlaubt: 8000–192000 Hz (z.B. 32000, 44100, 48000).")
        }
    }

    mutating func run() throws {
        let url = URL(fileURLWithPath: folderPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else {
            print("Fehler: Der Pfad \(folderPath) existiert nicht oder ist kein Ordner.")
            throw ExitCode.failure
        }
        
        FFmpegWrapper.cleanupOldTempDirectories()
        let session = ConversionSession()

        // Ab hier gehört das Terminal dem Renderer: Alle Session-Logs laufen über
        // ihn, damit sie nicht in die Pacman-Fortschrittsanzeige hineinschreiben.
        let renderer = TerminalRenderer()
        session.logSink = { renderer.emitLog($0) }

        // Setup SIGINT handler
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            // Läuft auf der Main-Queue, also mitten in der Redraw-Schleife: erst
            // die Fortschrittsanzeige abräumen, damit die Meldung lesbar bleibt.
            renderer.emitLog("🛑 Abbruchsignal (SIGINT) empfangen. Bereinige und beende...")
            FFmpegWrapper.cancelConversion(session: session)
            // Exit 130 = "durch SIGINT beendet" (128 + Signalnummer 2), Shell-Konvention.
            // NICHT 0: sonst würden aufrufende Skripte/AI-Agenten den Abbruch als Erfolg
            // werten, obwohl keine fertige Datei erzeugt wurde.
            Darwin.exit(130)
        }
        signal(SIGINT, SIG_IGN)
        sigintSource.resume()
        
        session.addFolder(url)
        
        // Wait for metadata fetching to complete
        session.metadataGroup.wait()
        // Der Titel/Autor wird vom Metadaten-Fetch per DispatchQueue.main.async
        // gesetzt. metadataGroup.wait() kehrt zurück, sobald der Hintergrund-Task
        // fertig ist — der main-Block, der den Titel setzt, ist dann zwar in der
        // Queue, aber noch nicht ausgeführt. Kurz den RunLoop drehen, damit der
        // Titel bereitsteht, BEVOR der Ausgabe-Dateiname daraus gebildet wird.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        guard !session.audioFiles.isEmpty else {
            print("Fehler: Keine gültigen Audiodateien im Ordner gefunden.")
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
        // Muss NACH metadataGroup.wait() + RunLoop-Tick passieren, sonst würde
        // der Metadaten-Fetch die Werte wieder überschreiben.
        if let title = title { session.title = title }
        if let author = author { session.author = author }

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
                try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                outputFile = target
            } else {
                FileHandle.standardError.write(Data("❌ --output muss ein existierender Ordner oder ein .m4b-Pfad sein: \(output)\n".utf8))
                throw ExitCode.failure
            }
        } else {
            outputFile = url.deletingLastPathComponent().appendingPathComponent("\(finalTitle).m4b")
        }
        
        print("Starte Konvertierung...")
        print("Zieldatei: \(outputFile.path)")
        
        if FileManager.default.fileExists(atPath: outputFile.path) {
            if force {
                print("⚠️ Die Zieldatei '\(outputFile.lastPathComponent)' existiert bereits. Überschreibe (--force gesetzt)...")
            } else if isatty(FileHandle.standardInput.fileDescriptor) == 0 {
                // Nicht-interaktiv (Pipe/CI/AI-Agent): nicht blockierend nachfragen,
                // sondern klar mit Fehlercode abbrechen und auf --force hinweisen.
                FileHandle.standardError.write(Data("❌ Zieldatei '\(outputFile.lastPathComponent)' existiert bereits. Zum Überschreiben --force verwenden.\n".utf8))
                throw ExitCode.failure
            } else {
                print("⚠️ Die Zieldatei '\(outputFile.lastPathComponent)' existiert bereits.")
                print("Möchten Sie die Datei überschreiben? (j/N): ", terminator: "")
                if let input = readLine(), input.lowercased() == "j" || input.lowercased() == "y" {
                    print("Datei wird überschrieben...")
                } else {
                    print("Vorgang abgebrochen.")
                    throw ExitCode(2)
                }
            }
        }
        
        FFmpegWrapper.convert(session: session, outputURL: outputFile)

        // Print ASCII Art Cover if verbose
        if verbose, let coverPath = session.coverPath, let img = NSImage(contentsOfFile: coverPath) {
            print("\n--- Cover ASCII Art ---")
            print(KloepplerCLI.generateAsciiArt(from: img, width: 40))
            print("-----------------------\n")
        }

        // RunLoop drehen, damit die DispatchQueue.main-Blöcke des Cores laufen.
        // Abbruchbedingung ist das definitive Abschluss-Signal lastConversionSucceeded
        // (vom Core genau einmal am Ende gesetzt). NICHT auf das transiente
        // isConverting==true warten -- bei sehr schnell abschließenden Läufen
        // (z.B. sofortiger Fehler) würde der RunLoop-Tick true UND false in einem
        // Durchlauf verarbeiten und die Schleife liefe sonst endlos.
        while session.lastConversionSucceeded == nil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

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

        // Ehrlicher Abschluss: nur bei echtem Erfolg Exit 0, sonst Fehler-Exit
        // (wichtig für Skripte/AI-Agenten, die den Exit-Code auswerten).
        if session.lastConversionSucceeded == true {
            print("🎉 Vorgang beendet. Datei liegt unter: \(outputFile.path)")
        } else {
            FileHandle.standardError.write(Data("❌ Vorgang fehlgeschlagen. Es wurde keine gültige Datei erzeugt.\n".utf8))
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
