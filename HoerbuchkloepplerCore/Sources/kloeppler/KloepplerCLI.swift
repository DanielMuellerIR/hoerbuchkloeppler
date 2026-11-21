import ArgumentParser
import HoerbuchkloepplerCore

enum CLIOutputFormat: String, ExpressibleByArgument, Sendable {
    case text
    case json
}

enum CLIEncodingMode: String, ExpressibleByArgument, Sendable {
    case parallel
    case standard

    init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

/// Hält einen ungültigen Eingabewert bis zur Validierung fest. So kann
/// ArgumentParser weiterhin Hilfe anzeigen, bevor es die Optionen prüft.
enum CLIOption<Value: ExpressibleByArgument & Sendable>: ExpressibleByArgument, Sendable {
    case accepted(Value)
    case invalid(String)

    init(argument: String) {
        if let value = Value(argument: argument) { self = .accepted(value) }
        else { self = .invalid(argument) }
    }

    var defaultValueDescription: String {
        switch self {
        case .accepted(let value): return value.defaultValueDescription
        case .invalid(let argument): return argument
        }
    }

    func validated(_ message: (String) -> String) throws -> Value {
        switch self {
        case .accepted(let value): return value
        case .invalid(let argument): throw ValidationError(message(argument))
        }
    }
}

/// Sendable-Snapshot der von ArgumentParser gefüllten Optionen. Die Parser-
/// Konformität bleibt dadurch nichtisoliert; nur die eigentliche Ausführung
/// wechselt anschließend auf den Main Actor.
struct CLIOptions: Sendable {
    let folderPath: String
    let project: String?
    let files: [String]
    let inspect: Bool
    let format: CLIOutputFormat
    let mode: CLIEncodingMode?
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
    let workers: Int?
    let importWorkers: Int?
    let analyzeLoudness: Bool
    let normalizeLoudness: Bool
    let narrator: String?
    let series: String?
    let volumeNumber: String?
    let language: String?
}

@main
struct KloepplerCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kloeppler",
        abstract: "Ein Kommandozeilen-Tool zum Generieren von M4B Hörbüchern aus Audiodateien."
    )

    @Argument(help: "Der absolute Pfad zum Ordner, der die Audiodateien enthält.")
    var folderPath: String?

    @Option(name: .long, help: "Versioniertes .hkproject mit bearbeiteter Reihenfolge öffnen.")
    var project: String?

    @Option(name: .customLong("file"), parsing: .singleValue, help: "Audiodatei in expliziter Reihenfolge; Option je Datei wiederholen.")
    var files: [String] = []

    @Flag(name: .long, help: "Quellen analysieren und Ausgabeplanung anzeigen, ohne Dateien anzulegen.")
    var inspect = false

    @Option(name: .long, help: "Ausgabeformat text oder json; Konvertierungen liefern mit json versionierte JSON-Laufereignisse.")
    var format: CLIOption<CLIOutputFormat> = .accepted(.text)

    @Option(name: .shortAndLong, help: "Der Kodierungsmodus: 'parallel' (Performance) oder 'standard' (Sequenziell).")
    var mode: CLIOption<CLIEncodingMode>?

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

    @Option(name: .long, help: "Maximale Encoding-Prozesse (1–32); automatisch höchstens vier.")
    var workers: Int?
    @Option(name: .long, help: "Gleichzeitige Quellanalysen (1–8, Default 4).")
    var importWorkers: Int?

    @Flag(name: .long, help: "Buchlautheit messen; zusätzlicher vollständiger Dekodier-/Analysepass und temporäre WAV-Dateien.")
    var analyzeLoudness = false
    @Flag(name: .long, help: "Buchweit auf -18 LUFS angleichen, durch Spitzenreserve begrenzt; impliziert Analyse.")
    var normalizeLoudness = false
    @Option(name: .long, help: "Sprecher; wird als MP4-Komponist gespeichert.")
    var narrator: String?
    @Option(name: .long, help: "Hörbuchreihe; wird als MP4-Gruppierung gespeichert.")
    var series: String?
    @Option(name: .long, help: "Bandnummer (1–65535).")
    var volumeNumber: String?
    @Option(name: .long, help: "Audiosprache als ISO-639-Code, z.B. deu oder eng.")
    var language: String?

    private var validatedFormat: CLIOutputFormat {
        get throws {
            try format.validated { _ in "--format erwartet text oder json." }
        }
    }

    private var validatedMode: CLIEncodingMode? {
        get throws {
            try mode?.validated { "Ungültiger --mode '\($0)'. Erlaubt: 'parallel' oder 'standard'." }
        }
    }

    func validate() throws {
        if let importWorkers, !(1...8).contains(importWorkers) { throw ValidationError("--import-workers erwartet 1–8.") }
        // ArgumentParser meldet auch ungültige Projekt-Metadaten als Usage-Fehler.
        if let language {
            do { _ = try BookMetadata.outputLanguage(language) }
            catch { throw ValidationError(error.localizedDescription) }
        }
        if let volumeNumber {
            do { try BookMetadata.validateVolumeNumber(volumeNumber) }
            catch { throw ValidationError(error.localizedDescription) }
        }
        _ = try validatedFormat
        guard (folderPath != nil ? 1 : 0) + (project != nil ? 1 : 0) + (!files.isEmpty ? 1 : 0) == 1 else {
            throw ValidationError("Genau einen Ordner, --project oder eine Folge von --file angeben.")
        }
        if let workers, !(1...32).contains(workers) { throw ValidationError("--workers erwartet 1–32.") }
        _ = try validatedMode
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
            folderPath: folderPath ?? "",
            project: project, files: files, inspect: inspect, format: try validatedFormat,
            mode: try validatedMode,
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
            force: force,
            workers: workers, importWorkers: importWorkers, analyzeLoudness: analyzeLoudness, normalizeLoudness: normalizeLoudness,
            narrator: narrator, series: series, volumeNumber: volumeNumber, language: language
        )
        try await CLIExecution(options: options).run()
    }
}
