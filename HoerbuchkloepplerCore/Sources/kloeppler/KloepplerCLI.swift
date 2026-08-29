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

    private let condition = NSCondition()
    private var receivedSignal: Int32?
    private var pendingSignals = 0
    private var announced = false
    private var phase: Phase = .preparing

    var shouldCancelPreparation: Bool {
        condition.lock()
        defer { condition.unlock() }
        return phase == .preparing
    }

    /// Sperrt den Phasenabschluss, bevor der Handler Core-Cancellation aufruft.
    /// Sonst kann dessen terminales Event die CLI zwischen akzeptiertem Cancel
    /// und `recordSignal` mit Exit 0/1 statt 128+Signal beenden.
    func beginSignal() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard phase != .finished else { return false }
        pendingSignals += 1
        return true
    }

    /// Akzeptiert das Signal nur, solange noch Arbeit abgebrochen werden kann.
    /// Ein vom Core nach dem letzten atomaren Commit abgelehnter Cancel darf
    /// keinen falschen Exit 130 mehr erzeugen.
    func recordSignal(
        _ signal: Int32,
        conversionOutcome: ConversionCancellationOutcome,
        preparationCancelled: Bool
    ) -> Bool {
        condition.lock()
        defer {
            pendingSignals -= 1
            condition.broadcast()
            condition.unlock()
        }
        guard phase != .finished else { return false }
        var accepted = false
        switch conversionOutcome {
        case .cancelled:
            accepted = true
        case .noActiveConversion:
            // In der Vorbereitung oder in der winzigen Lücke direkt vor dem
            // synchronen Anlegen des Conversion-Contexts bleibt das Signal offen.
            accepted = true
        case .rejected:
            accepted = phase == .preparing && preparationCancelled
        }
        if accepted, receivedSignal == nil { receivedSignal = signal }
        return accepted
    }

    func beginConversion() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard pendingSignals == 0, receivedSignal == nil else { return false }
        phase = .converting
        return true
    }

    /// Wartet auf einen bereits laufenden Signal-Handler, bevor die Phase
    /// unwiderruflich geschlossen wird. Der Handler braucht dafür keinen Main
    /// Actor und kann die Condition auch dann auflösen, wenn dieser Thread wartet.
    func finishExecution() -> Int32? {
        condition.lock()
        while pendingSignals > 0 { condition.wait() }
        phase = .finished
        let signal = receivedSignal
        condition.unlock()
        return signal
    }

    var wasReceived: Bool {
        condition.lock()
        defer { condition.unlock() }
        return receivedSignal != nil || pendingSignals > 0
    }

    func waitForExitCode() -> ExitCode? {
        condition.lock()
        while pendingSignals > 0 { condition.wait() }
        let signal = receivedSignal
        condition.unlock()
        return signal.map { ExitCode(128 + $0) }
    }

    func takeUnannouncedSignal() -> Int32? {
        condition.lock()
        defer { condition.unlock() }
        guard let signal = receivedSignal, !announced else { return nil }
        announced = true
        return signal
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

/// Erzeugt den GCD-Handler außerhalb des Main Actors. Wird die Closure direkt
/// in `execute` angelegt, erbt sie dessen Actor-Isolation und Swift 6 beendet
/// den Prozess beim Aufruf auf der Signal-Queue mit einem Laufzeitfehler.
private func makeInterruptHandler(
    session: ConversionSession,
    interruptState: InterruptState,
    signal: Int32
) -> @Sendable () -> Void {
    {
        guard interruptState.beginSignal() else { return }
        let preparationCancelled = interruptState.shouldCancelPreparation
            ? session.cancelPreparation()
            : false
        let outcome = FFmpegWrapper.cancelConversion(session: session)
        _ = interruptState.recordSignal(
            signal,
            conversionOutcome: outcome,
            preparationCancelled: preparationCancelled
        )
    }
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
            throw ValidationError("Ungültige --bitrate '\(bitrate)'. Erwartet werden 8 bis 320 kbit/s, z.B. '48k' oder '64000'.")
        }
        if let samplerate = samplerate, !(8000...48000).contains(samplerate) {
            throw ValidationError("Ungültige --samplerate \(samplerate). Erlaubt: 8000–48000 Hz (z.B. 32000, 44100, 48000).")
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

        let sourceURL = URL(fileURLWithPath: folderPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else {
            writeStandardError("Fehler: Der Pfad \(folderPath) existiert nicht oder ist kein Ordner.")
            throw ExitCode.failure
        }
        // Nach der Existenzprüfung den physischen Ordner festhalten. Sonst kann
        // ein später umgebogener Symlink sowohl die Quelle als auch das abgeleitete
        // Standard-Ausgabeziel unbemerkt auf einen anderen Datenträger lenken.
        let url = sourceURL.standardizedFileURL.resolvingSymlinksInPath()

        FFmpegWrapper.cleanupOldTempDirectories()
        // CLI-Aufrufe sind reproduzierbar: nicht gesetzte Optionen verwenden die
        // dokumentierten Defaults und hängen nicht von GUI-settings.json ab.
        let session = ConversionSession(settings: AudioSettings())

        // Ab hier gehört das Terminal dem Renderer: Alle Session-Logs laufen über
        // ihn, damit sie nicht in die Pacman-Fortschrittsanzeige hineinschreiben.
        let renderer = TerminalRenderer()
        session.logSink = { renderer.emitLog($0) }

        // SIGINT (Ctrl+C) und SIGTERM benutzen denselben geordneten Abbruchpfad.
        // `InterruptState` verhindert dabei, dass der Abschluss dem Handler
        // zuvorkommt und ein bereits akzeptiertes Signal als Exit 0 verloren geht.
        let interruptState = InterruptState()
        let signalQueue = DispatchQueue(label: "de.hoerbuchkloeppler.signals")
        let handledSignals: [Int32] = [SIGINT, SIGTERM]
        let signalSources = handledSignals.map { handledSignal in
            let source = DispatchSource.makeSignalSource(signal: handledSignal, queue: signalQueue)
            source.setEventHandler(handler: makeInterruptHandler(
                session: session,
                interruptState: interruptState,
                signal: handledSignal
            ))
            Darwin.signal(handledSignal, SIG_IGN)
            source.resume()
            return source
        }
        defer { signalSources.forEach { $0.cancel() } }

        func signalName(_ signal: Int32) -> String {
            signal == SIGTERM ? "SIGTERM" : "SIGINT"
        }

        func emitInterruptIfNeeded() {
            guard let receivedSignal = interruptState.takeUnannouncedSignal() else { return }
            renderer.emitLog("⚠️ \(signalName(receivedSignal)) empfangen. Lauf wird geordnet abgebrochen …")
        }

        func throwIfInterrupted() throws {
            guard interruptState.wasReceived else { return }
            guard let exitCode = interruptState.waitForExitCode() else { return }
            emitInterruptIfNeeded()
            throw exitCode
        }

        // Jeder Ausgang nach Installation der Signalquellen läuft durch denselben
        // Abschluss. So gewinnt ein bereits begonnener und anschließend
        // akzeptierter Signal-Handler auch gegen einen gleichzeitig entstehenden
        // Validierungs- oder Importfehler.
        var executionError: Error?
        do {
            session.beginPreparation()
            try throwIfInterrupted()
            // Ein ausdrückliches Cover oder --no-cover gewinnt ohnehin. In
            // diesen Fällen weder eingebettete Bilder noch Ordnerbilder vorab
            // dekodieren.
            await session.prepareFolder(
                url,
                analyzeArtwork: cover == nil && !noCover
            )

            try throwIfInterrupted()

            if !session.lastImportFailures.isEmpty {
                writeStandardError("Fehler: Der Ordnerimport wurde vollständig verworfen:")
                session.lastImportFailures.forEach {
                    writeStandardError("  \($0.sourceURL.lastPathComponent): \($0.message)")
                }
                throw ExitCode.failure
            }

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
                let coverURL = URL(fileURLWithPath: cover).standardizedFileURL.resolvingSymlinksInPath()
                let coverValues: URLResourceValues
                do {
                    coverValues = try coverURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                } catch {
                    writeStandardError("❌ Cover-Datei konnte nicht geprüft werden: \(cover)")
                    throw ExitCode.failure
                }
                let maximumCoverByteCount = 32 * 1024 * 1024
                guard coverValues.isRegularFile == true,
                      let coverByteCount = coverValues.fileSize,
                      coverByteCount <= maximumCoverByteCount else {
                    writeStandardError("❌ Cover muss eine reguläre Bilddatei mit höchstens 32 MiB sein: \(cover)")
                    throw ExitCode.failure
                }
                guard session.selectCover(url: coverURL) else {
                    writeStandardError("❌ Cover-Datei ist nicht als Bild lesbar: \(cover)")
                    throw ExitCode.failure
                }
            }
            try throwIfInterrupted()

            // Sichtbarer Linkname bestimmt wie bisher den Fallback-Titel; nur das
            // Lesen selbst verwendet den aufgelösten physischen Ordner.
            let rawTitle = session.title.isEmpty ? sourceURL.lastPathComponent : session.title
            let finalTitle = KloepplerCLI.sanitizeFilename(rawTitle)
            let outputFile: URL
            if let output = output {
                var outIsDir: ObjCBool = false
                let outExists = FileManager.default.fileExists(atPath: output, isDirectory: &outIsDir)
                if outExists && outIsDir.boolValue {
                    // Ordner angegeben: Dateiname wie bisher aus dem Titel bilden
                    let outputDirectory = URL(fileURLWithPath: output)
                        .standardizedFileURL.resolvingSymlinksInPath()
                    outputFile = outputDirectory.appendingPathComponent("\(finalTitle).m4b")
                } else if output.lowercased().hasSuffix(".m4b") {
                    // Voller Zielpfad: Eltern-Ordner muss existieren (bei Bedarf anlegen)
                    let target = URL(fileURLWithPath: output).standardizedFileURL
                    do {
                        try FileManager.default.createDirectory(
                            at: target.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                    } catch {
                        writeStandardError("❌ Ausgabeordner konnte nicht angelegt werden: \(error.localizedDescription)")
                        throw ExitCode.failure
                    }
                    let resolvedParent = target.deletingLastPathComponent().resolvingSymlinksInPath()
                    outputFile = resolvedParent.appendingPathComponent(target.lastPathComponent)
                } else {
                    writeStandardError("❌ --output muss ein existierender Ordner oder ein .m4b-Pfad sein: \(output)")
                    throw ExitCode.failure
                }
            } else {
                // Das dokumentierte Standardziel liegt neben dem angegebenen
                // Quellpfad, nicht neben dem Ziel eines Quellordner-Symlinks. Nur
                // dessen Elternordner wird physisch gebunden.
                let sourceParent = sourceURL.standardizedFileURL
                    .deletingLastPathComponent().resolvingSymlinksInPath()
                outputFile = sourceParent.appendingPathComponent("\(finalTitle).m4b")
            }

            let conversionPlan = FFmpegWrapper.makeConversionPlan(
                files: session.audioFiles,
                outputURL: outputFile,
                maxDurationHours: session.settings.maxDurationHours
            )
            // Auch ein expliziter --output-Name kann zu lang sein; bei Split-Läufen
            // kommt der konkrete `-01`-Suffix erst im Plan hinzu. Vor jedem
            // Dateisystemzugriff deshalb die tatsächlichen Zielnamen prüfen.
            if let invalidOutput = conversionPlan.outputURLs.first(where: {
                $0.lastPathComponent.utf8.count > Int(NAME_MAX)
            }) {
                writeStandardError(
                    "❌ Ausgabe-Dateiname ist länger als \(NAME_MAX) UTF-8-Bytes: "
                    + invalidOutput.lastPathComponent
                )
                throw ExitCode.failure
            }
            print("Starte Konvertierung...")
            print(conversionPlan.outputURLs.count == 1 ? "Zieldatei:" : "Zieldateien:")
            conversionPlan.outputURLs.forEach { print("  \($0.path)") }

            let existingOutputs = conversionPlan.outputURLsRequiringOverwriteConfirmation
            if !existingOutputs.isEmpty {
                let names = existingOutputs.map(\.lastPathComponent).joined(separator: ", ")
                if force {
                    print("⚠️ Vorhandene Zieldatei(en) werden überschrieben (--force): \(names)")
                } else if isatty(FileHandle.standardInput.fileDescriptor) == 0
                            || isatty(FileHandle.standardOutput.fileDescriptor) == 0 {
                    // Nur fragen, wenn Eingabe UND sichtbare Ausgabe an Terminals
                    // hängen. Bei umgeleitetem stdout wäre die Frage unsichtbar.
                    writeStandardError("❌ Zieldatei(en) existieren bereits: \(names). Zum Überschreiben --force verwenden.")
                    throw ExitCode.failure
                } else {
                    print("⚠️ Diese Zieldatei(en) existieren bereits: \(names)")
                    print("Möchten Sie die Dateien überschreiben? (j/N): ", terminator: "")
                    if let input = readLine(unlessInterrupted: interruptState),
                       input.lowercased() == "j" || input.lowercased() == "y" {
                        print("Datei wird überschrieben...")
                    } else if interruptState.wasReceived {
                        try throwIfInterrupted()
                    } else {
                        print("Vorgang abgebrochen.")
                        throw ExitCode(2)
                    }
                }
            }

            guard interruptState.beginConversion() else {
                try throwIfInterrupted()
                throw ExitCode.failure
            }
            if case .rejected(let message) = FFmpegWrapper.convert(
                session: session,
                plan: conversionPlan
            ) {
                writeStandardError("❌ Konvertierung konnte nicht gestartet werden: \(message)")
                throw ExitCode.failure
            }
            // Ein Signal kann genau zwischen Phasenwechsel und dem synchronen
            // Erzeugen des Contexts eintreffen. Dann jetzt den neuen Context stoppen.
            if interruptState.wasReceived {
                _ = FFmpegWrapper.cancelConversion(session: session)
            }

            // Print ASCII Art Cover if verbose
            if verbose, let img = session.coverImage {
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
                emitInterruptIfNeeded()

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

            // Ein akzeptierter Abbruch setzt den Core-Abschluss absichtlich auf
            // false. Vor der normalen Fehlerausgabe abfangen, damit SIGINT/
            // SIGTERM nicht zusätzlich als Konvertierungsfehler erscheinen.
            try throwIfInterrupted()

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
        } catch {
            executionError = error
        }

        // Exit 128+Signal erst NACH dem definitiven Worker-/Handler-Abschluss.
        // So sind Prozesse, Temp-Verzeichnisse und große .partial-Dateien sicher
        // bereinigt, und ein akzeptiertes Signal kann keinem Fehlerausgang
        // zeitlich hinterherlaufen.
        let receivedSignal = interruptState.finishExecution()
        emitInterruptIfNeeded()
        if let receivedSignal { throw ExitCode(128 + receivedSignal) }
        if let executionError { throw executionError }
    }

    /// Macht aus einem (Metadaten-)Titel einen sicheren Dateinamen: Pfad- und
    /// Steuerzeichen (`/`, `:`, `\`, Umbrüche) werden durch `-` ersetzt, Rand-
    /// Whitespace/Punkte entfernt und der UTF-8-Name auf APFS/HFS-kompatible
    /// Länge begrenzt. Sonst landete der Output bei einem Titel mit `/` im
    /// falschen Verzeichnis oder scheiterte erst tief im Core mit ENAMETOOLONG.
    static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\\n\r\t").union(.controlCharacters)
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .").union(.whitespacesAndNewlines))
        guard !cleaned.isEmpty else { return "Hoerbuch" }

        // NAME_MAX beträgt auf den unterstützten macOS-Dateisystemen 255 Byte.
        // Neben `.m4b` bleibt Platz für den größtmöglichen Split-Suffix
        // `-<Int.max>`. Zeichen werden nie mitten in ihrer UTF-8-Folge getrennt.
        let reservedByteCount = ".m4b".utf8.count + 1 + String(Int.max).utf8.count
        let maximumBaseByteCount = Int(NAME_MAX) - reservedByteCount
        var truncated = ""
        var usedByteCount = 0
        for character in cleaned {
            let byteCount = String(character).utf8.count
            guard usedByteCount + byteCount <= maximumBaseByteCount else { break }
            truncated.append(character)
            usedByteCount += byteCount
        }
        let safe = truncated.trimmingCharacters(
            in: CharacterSet(charactersIn: " .").union(.whitespacesAndNewlines)
        )
        return safe.isEmpty ? "Hoerbuch" : safe
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
        guard image.size.width > 0, image.size.height > 0,
              image.size.width.isFinite, image.size.height.isFinite,
              width > 0 else { return "" }

        // Der Aufrufer nutzt 40 Spalten. Die Obergrenzen schützen die Hilfs-
        // funktion zusätzlich vor riesigen Allokationen bei extremen Bildmaßen.
        let renderWidth = min(width, 400)

        var rect = NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return "" }

        // Calculate height to maintain aspect ratio (terminal characters are roughly 2x as tall as they are wide)
        let aspectRatio = image.size.height / image.size.width
        let scaledHeight = Double(renderWidth) * Double(aspectRatio) * 0.5
        guard scaledHeight.isFinite else { return "" }
        let height = max(1, Int(min(200, scaledHeight)))

        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bytesPerPixel = 1
        let bytesPerRow = bytesPerPixel * renderWidth

        var pixelData = [UInt8](repeating: 0, count: renderWidth * height)

        guard let context = CGContext(data: &pixelData,
                                      width: renderWidth,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return "" }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: renderWidth, height: height))

        var result = ""
        for y in 0..<height {
            for x in 0..<renderWidth {
                let offset = (height - 1 - y) * renderWidth + x // CGContext draws inverted on macOS
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
