import SwiftUI
import Foundation
import Combine
import AVFoundation
import AppKit

public struct TagCandidate: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let type: String
    public let key: String
    public let value: String
    public init(type: String, key: String, value: String) { self.type = type; self.key = key; self.value = value }
}

public enum LogType: Sendable {
    case info      // Standardtext (Primary Color)
    case highlight // Pfade, Tool-Outputs, Befehle (AccentColor)
    case dim       // Light gray (MediaInfo output)
}

public struct LogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let type: LogType
    public let message: String
    public let date: Date
    public init(type: LogType, message: String, date: Date) { self.type = type; self.message = message; self.date = date }
}

public struct SegmentStatus: Equatable, Sendable {
    public let filename: String
    public var progress: Double
    public init(filename: String, progress: Double) { self.filename = filename; self.progress = progress }
}

public struct ImportToken: Equatable, Sendable {
    fileprivate let generation: UUID
    fileprivate let coverRevision: UInt
}

struct MetadataResolution: Equatable, Sendable {
    let title: String
    let author: String
    let shouldShowSelection: Bool
}

/// Eine gefundene Datei mit sichtbarem Quellpfad und physischer Lese-URL.
///
/// `source` ist der Pfad, unter dem der Nutzer die Datei sieht. `resolved` ist
/// die reguläre Datei, die AVFoundation und ffmpeg öffnen. Bei gewöhnlichen
/// Dateien sind beide gleich; bei einem Symlink bleibt so dessen bewusst
/// gewählter Name erhalten, ohne den Link selbst an Audio-APIs zu übergeben.
public struct FoundFile: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case audio
        case image
        case unsupported
    }

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "flac", "m4b", "mp4"
    ]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png"]
    private static let chapterContainerExtensions: Set<String> = ["m4b", "mp4"]

    public let source: URL
    public let resolved: URL

    public init(source: URL, resolved: URL) {
        self.source = source
        self.resolved = resolved
    }

    public var readURL: URL { resolved }

    /// Der Typ darf am sichtbaren Namen oder am Ziel erkennbar sein. Ob eine
    /// Datei Kapitelcontainer ist, entscheidet dagegen ausschließlich die
    /// wirklich gelesene Datei.
    public var kind: Kind {
        let extensions = [source.pathExtension, resolved.pathExtension]
            .map { $0.lowercased() }
        if extensions.contains(where: Self.audioExtensions.contains) { return .audio }
        if extensions.contains(where: Self.imageExtensions.contains) { return .image }
        return .unsupported
    }

    public var isChapterContainer: Bool {
        Self.chapterContainerExtensions.contains(resolved.pathExtension.lowercased())
    }

    var isSymbolicLink: Bool {
        source.standardizedFileURL != resolved.standardizedFileURL
    }
}

public struct AudioImportFailure: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case unreadableDuration
        case noAudioTrack
        case chapterAnalysisTimedOut
        case analysisFailed
    }

    public let sourceURL: URL
    public let reason: Reason

    public init(sourceURL: URL, reason: Reason) {
        self.sourceURL = sourceURL
        self.reason = reason
    }

    public var message: String {
        switch reason {
        case .unreadableDuration:
            return "Keine positive Audiodauer lesbar"
        case .noAudioTrack:
            return "Kein lesbarer Audio-Stream enthalten"
        case .chapterAnalysisTimedOut:
            return "Kapitelanalyse hat das Zeitlimit überschritten"
        case .analysisFailed:
            return "Audioanalyse fehlgeschlagen"
        }
    }

    public var logMessage: String {
        "❌ \(sourceURL.lastPathComponent): \(message)."
    }
}

/// Typisiertes Ergebnis genau einer Eingangsdatei. Ein absichtlicher Skip
/// (beispielsweise ein gedropptes Bild) bleibt von Analysefehler und Abbruch
/// unterscheidbar, damit ein Mehrdateien-Import atomar entschieden werden kann.
public enum AudioLoadResult: Sendable {
    case success(files: [AudioFile], warnings: [String])
    case skipped
    case failure(AudioImportFailure)
    case cancelled

    public var files: [AudioFile] {
        guard case .success(let files, _) = self else { return [] }
        return files
    }

    public var warnings: [String] {
        guard case .success(_, let warnings) = self else { return [] }
        return warnings
    }

    public var failures: [AudioImportFailure] {
        guard case .failure(let failure) = self else { return [] }
        return [failure]
    }

    public var wasCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

struct FileDiscoveryResult: Sendable {
    let files: [FoundFile]
    let failureDescription: String?
}

/// `DirectoryEnumerator` darf seinen Fehler-Handler nebenläufig aufrufen. Der
/// Recorder hält deshalb nur den ersten Fehler hinter einer kleinen Sperre fest.
private final class DirectoryScanFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var firstFailure: String?

    func record(url: URL, error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard firstFailure == nil else { return }
        firstFailure = "\(url.path): \(error.localizedDescription)"
    }

    func snapshot() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return firstFailure
    }
}

/// Besitzt nur die externen Prozesse des Imports (Kapitel- und Metadatenanalyse).
/// Damit kann die CLI schon vor dem eigentlichen Konvertierungs-Context auf
/// Ctrl-C reagieren, ohne Prozesse eines anderen Fensters anzufassen.
private final class PreparationContext: ToolProcessContext, @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]
    private var taskCancellations: [UUID: @Sendable () -> Void] = [:]
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Start und Registrierung passieren unter derselben Sperre wie `cancel()`.
    /// Ein Abbruch gewinnt dadurch entweder vor dem Spawn oder sieht danach den
    /// vollständigen Prozessgruppen-Besitz.
    func run(_ process: Process) throws -> Bool {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return false
        }
        processes[ObjectIdentifier(process)] = process
        do {
            try process.run()
            ProcessTerminator.recordOwnedProcessGroup(process)
            lock.unlock()
            return true
        } catch {
            processes.removeValue(forKey: ObjectIdentifier(process))
            lock.unlock()
            throw error
        }
    }

    func unregister(_ process: Process) {
        lock.lock()
        processes.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
        ProcessTerminator.forgetOwnedProcessGroup(process)
    }

    /// Registriert einen Swift-Task zusätzlich zu den externen Prozessen. So
    /// erreicht der synchrone SIGINT-Pfad auch gerade suspendierte
    /// AVFoundation-Aufrufe und nicht nur ffmpeg/mediainfo.
    func registerTaskCancellation(_ cancellation: @escaping @Sendable () -> Void) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return nil }
        let id = UUID()
        taskCancellations[id] = cancellation
        return id
    }

    func unregisterTaskCancellation(_ id: UUID) {
        lock.lock()
        taskCancellations.removeValue(forKey: id)
        lock.unlock()
    }

    @discardableResult
    func cancel() -> Bool {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return false
        }
        cancelled = true
        let activeProcesses = Array(processes.values)
        let activeTaskCancellations = Array(taskCancellations.values)
        processes.removeAll()
        taskCancellations.removeAll()
        lock.unlock()
        activeTaskCancellations.forEach { $0() }
        ProcessTerminator.terminateInBackground(activeProcesses) {}
        return true
    }
}

/// Verwaltet den jeweils aktuellen Vorbereitungslauf außerhalb des Main Actors.
/// Der Signal-Handler der CLI muss Prozesse synchron abbrechen können, während
/// der sichtbare Sitzungszustand konsequent auf dem Main Actor bleibt.
private final class PreparationCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var current: PreparationContext?

    func begin() {
        let next = PreparationContext()
        lock.lock()
        let previous = current
        current = next
        lock.unlock()
        previous?.cancel()
    }

    func context() -> PreparationContext? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func cancel() -> Bool {
        context()?.cancel() ?? false
    }
}

/// Thread-sicherer Besitz des aktuellen Konvertierungslaufs. Diese kleine
/// Synchronisationsschicht enthält keinen UI-Zustand; dadurch kann SIGINT den
/// Worker abbrechen, ohne die Main-Actor-Isolation der Session zu umgehen.
private final class ConversionCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var active: ConversionContext?
    private var finished = false

    func begin(log: @escaping @Sendable (UUID, String) -> Void) -> ConversionContext {
        let next = ConversionContext(log: log)
        lock.lock()
        let previous = active
        active = next
        finished = false
        lock.unlock()
        previous?.cancel()
        return next
    }

    func current() -> ConversionContext? {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func isCurrent(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active?.id == id
    }

    func hasFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func end(_ id: UUID) {
        lock.lock()
        if active?.id == id {
            active = nil
            finished = true
        }
        lock.unlock()
    }
}

private enum ConversionEvent: Sendable {
    case log(String, LogType, UUID)
    case verboseLog(String, UUID)
    case segmentReset(String?, UUID)
    case segmentInitialization(Int, String, UUID)
    case progress(Double, Int?, Double?, UUID)
    case finished(Bool, Bool, [URL], UUID)
    case cancellationStarted(UUID)
    case barrier(CheckedContinuation<Void, Never>)
}

/// Thread-sichere Eingangsqueue für alle Nachrichten eines ffmpeg-Workers.
/// Genau ein Main-Actor-Task konsumiert den Stream; damit bleibt die Reihenfolge
/// erhalten, ohne einen blockierenden Worker auf den Main Actor warten zu lassen.
private final class ConversionEventQueue: @unchecked Sendable {
    private let stream: AsyncStream<ConversionEvent>
    private let continuation: AsyncStream<ConversionEvent>.Continuation
    private var consumerTask: Task<Void, Never>?

    init() {
        let pair = AsyncStream<ConversionEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    @MainActor
    func start(
        handler: @escaping @MainActor @Sendable (ConversionEvent) -> Void
    ) {
        let stream = stream
        consumerTask = Task { @MainActor in
            for await event in stream {
                handler(event)
            }
        }
    }

    func send(_ event: ConversionEvent) {
        continuation.yield(event)
    }

    deinit {
        continuation.finish()
        consumerTask?.cancel()
    }
}

@MainActor
public final class ConversionSession: ObservableObject, Identifiable {
    public let id = UUID()
    @Published public var settings: AudioSettings
    public init(settings: AudioSettings = SettingsManager.shared.loadSettings()) {
        self.settings = settings.normalized()
        conversionEventQueue.start { [weak self] event in
            self?.applyConversionEvent(event)
        }
    }
    
    @Published public var audioFiles: [AudioFile] = [] {
        didSet {
            if audioFiles.isEmpty {
                invalidateImportWork()
                clearMetadata()
            }
        }
    }
    
    @Published public var coverImage: NSImage?
    @Published public var coverPath: String?
    @Published public var isPreparingArtwork = false
    /// Rohdaten eines eingebetteten Covers (aus einer Audiodatei extrahiert), das
    /// NICHT als separate Bilddatei vorliegt. Wird vor der Kodierung in eine
    /// temporäre Datei geschrieben, damit ffmpeg es einbetten kann — sonst ginge
    /// ein nur eingebettetes Cover im Output verloren.
    public var embeddedCoverData: Data?
    private var importGeneration = UUID()
    private var artworkRequest = UUID()
    private var coverRevision: UInt = 0
    public private(set) var isCoverSuppressed = false
    private var pendingImportOperations = 0
    @Published public private(set) var isImporting = false
    @Published public var importErrorMessage: String?
    public private(set) var lastImportFailures: [AudioImportFailure] = []
    private var pendingImportAudioFiles: [AudioFile] = []
    private var pendingImportImageURLs: [URL] = []
    private var pendingImportArtwork: Data?
    private var pendingImportWarnings: [String] = []
    private var pendingImportFailures: [AudioImportFailure] = []
    private var pendingImportWasCancelled = false
    private var pendingImportFolderURL: URL?
    private var pendingImportCanRepresentFolder = false
    private var cliSourceFolderURL: URL?
    private var cliRepresentedFileIDs = Set<UUID>()
    private var cliRepresentedChapterTitles: [UUID: String] = [:]
    private nonisolated let preparationCoordinator = PreparationCoordinator()
    @Published public var title: String = ""
    @Published public var author: String = ""
    @Published public var genre: String = "Hörbuch"
    
    // --- KONVERSION STATUS & LOGGING ---
    @Published public var isConverting: Bool = false
    @Published public var showOverlay: Bool = false
    @Published public var progress: Double = 0.0
    @Published public var conversionStatus: String = "Bereit"
    @Published public internal(set) var completedOutputURLs: [URL] = []
    /// Ergebnis des letzten Konvertierungslaufs (nil = noch nicht beendet,
    /// true = erfolgreich, false = mit Fehler/abgebrochen). Erlaubt der CLI
    /// einen korrekten Exit-Code statt blind "Erfolg" zu melden.
    public var lastConversionSucceeded: Bool?

    private nonisolated let conversionCoordinator = ConversionCoordinator()
    private nonisolated let conversionEventQueue = ConversionEventQueue()

    /// Beginnt einen abbrechbaren Import-/Metadatenlauf. Die CLI startet ihn vor
    /// dem asynchron erwarteten Ordnerscan.
    public nonisolated func beginPreparation() {
        preparationCoordinator.begin()
    }

    @discardableResult
    public nonisolated func cancelPreparation() -> Bool {
        preparationCoordinator.cancel()
    }

    private nonisolated func currentPreparationContext() -> PreparationContext? {
        preparationCoordinator.context()
    }

    private nonisolated func preparationCancellationRequested() -> Bool {
        AudioFile.taskCancellationRequested()
            || currentPreparationContext()?.isCancelled == true
    }

    /// Führt einen Vorbereitungsschritt als registrierten Swift-Task aus. Der
    /// Signalpfad kann dessen Handle synchron canceln; der Aufrufer wartet
    /// trotzdem auf das saubere Ende, bevor die CLI mit Exit 130 zurückkehrt.
    public nonisolated func runPreparationTask(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) async {
        let context = currentPreparationContext()
        let task = Task { @MainActor in await operation() }
        guard let context else {
            await task.value
            return
        }
        guard let registration = context.registerTaskCancellation({ task.cancel() }) else {
            task.cancel()
            await task.value
            return
        }
        await task.value
        context.unregisterTaskCancellation(registration)
    }

    /// GUI-Variante mit Importbindung. Ein verspätet liefernder Provider eines
    /// alten Drops darf seine Analyse nicht im Prozess-Context des neueren Drops
    /// starten. Der Token wird deshalb vor der Registrierung und nochmals im
    /// eigentlichen Main-Actor-Task geprüft.
    public func runImportTask(
        _ token: ImportToken,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) async {
        guard isCurrentImport(token) else { return }
        let context = currentPreparationContext()
        let task = Task { @MainActor [weak self] in
            guard let self, self.isCurrentImport(token) else { return }
            await operation()
        }
        guard let context else {
            await task.value
            return
        }
        guard let registration = context.registerTaskCancellation({ task.cancel() }) else {
            task.cancel()
            await task.value
            return
        }
        await task.value
        context.unregisterTaskCancellation(registration)
    }

    /// Vollständiger CLI-Ordnerimport als abbrechbarer Vorbereitungstask.
    public nonisolated func prepareFolder(_ url: URL) async {
        await runPreparationTask { @MainActor [weak self] in
            await self?.addFolder(url)
        }
    }

    /// Liest Kapitel mit einem optional laufenden Vorbereitungs-Context. Das
    /// strukturierte Dateipaar verhindert, dass sichtbarer Pfad und Lese-URL
    /// an zwei gleich typisierten Parametern vertauscht werden.
    private nonisolated func extractChapterResult(
        from file: FoundFile,
        importToken: ImportToken? = nil
    ) async -> ChapterExtractionResult {
        let context = currentPreparationContext()
        return await AudioFile.extractChaptersControlled(
            from: file,
            shouldCancel: { context?.isCancelled ?? false },
            runProcess: { process in
                if let context { return try context.run(process) }
                try process.run()
                ProcessTerminator.recordOwnedProcessGroup(process)
                return true
            },
            unregisterProcess: { process in
                if let context {
                    context.unregister(process)
                } else {
                    ProcessTerminator.forgetOwnedProcessGroup(process)
                }
            },
            log: { [weak self] message in
                Task { @MainActor in
                    guard let self else { return }
                    if let importToken {
                        self.addImportLog(message, token: importToken)
                    } else {
                        self.addLog(message)
                    }
                }
            }
        )
    }

    public nonisolated func extractChapters(from file: FoundFile) async -> [AudioFile]? {
        guard file.isChapterContainer else { return nil }
        switch await extractChapterResult(from: file) {
        case .files(let files): return files
        case .failed: return []
        case .cancelled: return []
        }
    }

    /// Analysiert genau eine gefundene Audiodatei. Ordner- und Einzeldatei-
    /// Import benutzen damit dieselbe Typ-, Symlink- und Dauerlogik.
    public nonisolated func loadAudioFiles(
        from file: FoundFile,
        importToken: ImportToken? = nil
    ) async -> AudioLoadResult {
        guard file.kind == .audio else { return .skipped }
        let candidates: [AudioFile]
        if file.isChapterContainer {
            switch await extractChapterResult(from: file, importToken: importToken) {
            case .files(let files): candidates = files
            case .failed(let reason):
                return .failure(AudioImportFailure(sourceURL: file.source, reason: reason))
            case .cancelled:
                return .cancelled
            }
        } else {
            candidates = [await AudioFile(foundFile: file)]
        }
        guard !preparationCancellationRequested() else { return .cancelled }

        switch await AudioFile.audioTrackAvailability(at: file.readURL) {
        case .available:
            break
        case .missing:
            return .failure(AudioImportFailure(sourceURL: file.source, reason: .noAudioTrack))
        case .unreadable:
            return .failure(AudioImportFailure(sourceURL: file.source, reason: .analysisFailed))
        case .cancelled:
            return .cancelled
        }

        for candidate in candidates {
            guard candidate.duration.isFinite, candidate.duration > 0 else {
                return .failure(
                    AudioImportFailure(sourceURL: file.source, reason: .unreadableDuration)
                )
            }
        }
        return .success(files: candidates, warnings: [])
    }

    /// Startet einen neuen Lauf und macht einen eventuell noch auslaufenden
    /// Vorgänger ungültig. Dessen spätere Completion darf den neuen UI-State
    /// dadurch nicht mehr überschreiben.
    func beginConversionRun() -> ConversionContext {
        let queue = conversionEventQueue
        return conversionCoordinator.begin { runID, message in
            queue.send(.log(message, .highlight, runID))
        }
    }

    nonisolated func currentConversionContext() -> ConversionContext? {
        conversionCoordinator.current()
    }

    nonisolated func isCurrentConversion(_ id: UUID) -> Bool {
        conversionCoordinator.isCurrent(id)
    }

    nonisolated func hasFinishedConversion() -> Bool {
        conversionCoordinator.hasFinished()
    }

    func endConversion(_ id: UUID) {
        conversionCoordinator.end(id)
    }
    
    // Strukturierte Logs für GUI und Terminal
    @Published public var eventLogs: [LogEntry] = []
    @Published public var logString: String = "" // Für Legacy/Fallback
    @Published public var segmentProgress: [Int: SegmentStatus] = [:]

    @Published public var titleCandidates: [TagCandidate] = []
    @Published public var authorCandidates: [TagCandidate] = []
    @Published public var showSelectionUI = false
    @Published public var selectedFileInfoText: String = ""
    @Published public var showInfoSheet = false
    @Published public var isFetchingInfo = false

    private static let logDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    /// Ziel für die Terminal-Ausgabe von `addLog`/`logVerbose`.
    ///
    /// Standard (`nil`): direkt per `print` auf stdout — so verhält sich die GUI-App
    /// wie bisher (Logzeilen landen in der Xcode-Konsole).
    ///
    /// Die CLI hängt hier ihren Renderer ein: der räumt vor jeder Logzeile den
    /// Pacman-Statusblock ab und zeichnet ihn danach neu. Ohne diese Kopplung
    /// schreibt das Log mitten in die laufende Redraw-Schleife, deren
    /// Cursor-Buchführung stimmt danach nicht mehr, und sie löscht die falschen
    /// Zeilen.
    ///
    /// Wird immer auf dem Main Actor aufgerufen; der Renderer braucht deshalb
    /// keine eigene Sperre. Setzen ebenfalls nur dort (vor dem Start).
    public var logSink: ((String) -> Void)?

    /// Gibt eine fertige Zeile ins Terminal aus — über die Senke, falls gesetzt.
    /// Nur auf dem Main Actor aufrufen.
    private func emit(_ line: String) {
        if let logSink = logSink { logSink(line) } else { print(line) }
    }

    // Main-Actor-isoliertes Loggen mit Darstellungstypen.
    public func addLog(_ message: String, type: LogType = .info) {
        let entry = LogEntry(type: type, message: message, date: Date())
        eventLogs.append(entry)
        // `logString` dient nur dem „Gesamtes Log kopieren“-Fallback. Den bereits
        // aufgebauten Text nicht für jede neue Zeile aus allen Einträgen neu
        // erzeugen: Bei langen Läufen blockierte diese quadratische Arbeit den
        // Main Actor zunehmend.
        let appendedText = logString.isEmpty ? message : "\n\(message)"
        logString.append(contentsOf: appendedText)
        let timeStr = ConversionSession.logDateFormatter.string(from: entry.date)
        emit("[\(timeStr)] \(message)")
    }

    public func logVerbose(_ message: String) {
        guard settings.isVerbose else { return }
        // Verbose-Zeilen gehen bewusst nur ins Terminal, nicht ins UI-Log — sonst
        // wird die Oberfläche zugemüllt. Die Ausgabe läuft trotzdem über den
        // Main Actor: Aufrufer sind u.a. die parallelen Encoding-Threads, deren
        // rohes print() sonst nebenläufig in die Fortschrittsanzeige der CLI
        // schreiben würde.
        emit("[VERBOSE] \(message)")
    }

    /// Sichere Brücke für den blockierenden ffmpeg-Worker. Der Worker darf die
    /// Session als Main-Actor-Objekt referenzieren, aber ihren Zustand nur über
    /// diese gezielten Nachrichten verändern.
    nonisolated func enqueueLog(
        _ message: String,
        type: LogType = .info,
        runID: UUID
    ) {
        conversionEventQueue.send(.log(message, type, runID))
    }

    nonisolated func enqueueVerboseLog(_ message: String, runID: UUID) {
        conversionEventQueue.send(.verboseLog(message, runID))
    }

    nonisolated func enqueueSegmentReset(
        title: String?,
        runID: UUID
    ) {
        conversionEventQueue.send(.segmentReset(title, runID))
    }

    nonisolated func enqueueSegmentInitialization(
        index: Int,
        filename: String,
        runID: UUID
    ) {
        conversionEventQueue.send(.segmentInitialization(index, filename, runID))
    }

    nonisolated func enqueueProgress(
        _ value: Double,
        segmentIndex: Int? = nil,
        segmentProgress: Double? = nil,
        runID: UUID
    ) {
        conversionEventQueue.send(.progress(value, segmentIndex, segmentProgress, runID))
    }

    /// Übernimmt das Endergebnis des Workers in genau EINER Main-Actor-Nachricht,
    /// inklusive der erfolgreich erzeugten Ziel-URLs. Früher meldete eine
    /// separate Task jede fertige Datei einzeln; unstrukturierte Tasks haben
    /// aber keine garantierte Reihenfolge — lief der Abschluss zuerst, entfernte
    /// `endConversion` den Kontext und die Ausgabe-Meldung fiel am
    /// `isCurrentConversion`-Guard durch (die CLI meldete dann fälschlich,
    /// es sei keine gültige Datei erzeugt worden).
    nonisolated func enqueueConversionFinished(
        success: Bool,
        cancelled: Bool,
        completedOutputs: [URL],
        runID: UUID
    ) {
        conversionEventQueue.send(.finished(success, cancelled, completedOutputs, runID))
    }

    nonisolated func enqueueCancellationStarted(runID: UUID) {
        conversionEventQueue.send(.cancellationStarted(runID))
    }

    /// Wartet, bis alle zuvor eingereihten Worker-Ereignisse angewandt oder als
    /// veraltet verworfen wurden. Produktion braucht keine Blockade; Tests nutzen
    /// die Barriere für deterministische Race-Nachweise.
    nonisolated func flushConversionEvents() async {
        await withCheckedContinuation { continuation in
            conversionEventQueue.send(.barrier(continuation))
        }
    }

    private func applyConversionEvent(_ event: ConversionEvent) {
        switch event {
        case let .log(message, type, runID):
            guard isCurrentConversion(runID) else { return }
            addLog(message, type: type)

        case let .verboseLog(message, runID):
            guard isCurrentConversion(runID) else { return }
            logVerbose(message)

        case let .segmentReset(title, runID):
            guard isCurrentConversion(runID) else { return }
            segmentProgress = [:]
            if let title {
                initSegmentProgress(index: 0, filename: title, runID: runID)
            }

        case let .segmentInitialization(index, filename, runID):
            guard isCurrentConversion(runID) else { return }
            initSegmentProgress(index: index, filename: filename, runID: runID)

        case let .progress(value, segmentIndex, newSegmentProgress, runID):
            guard isCurrentConversion(runID) else { return }
            progress = max(progress, value)
            if let segmentIndex, let newSegmentProgress {
                updateSegmentProgress(
                    index: segmentIndex,
                    progress: newSegmentProgress,
                    runID: runID
                )
            }

        case let .finished(success, cancelled, completedOutputs, runID):
            guard isCurrentConversion(runID) else { return }
            completedOutputURLs = completedOutputs
            isConverting = false
            progress = success ? 1.0 : progress
            lastConversionSucceeded = success
            if cancelled {
                conversionStatus = "Abgebrochen"
            } else {
                conversionStatus = success ? "Erfolgreich abgeschlossen" : "Mit Fehlern beendet"
                addLog(
                    success ? "🏁 Alle Vorgänge beendet." : "🏁 Vorgang mit Fehlern beendet.",
                    type: .highlight
                )
            }
            endConversion(runID)

        case let .cancellationStarted(runID):
            guard isCurrentConversion(runID) else { return }
            conversionStatus = "Abbruch läuft …"
            addLog("🛑 Vorgang wird abgebrochen und bereinigt.", type: .info)

        case let .barrier(continuation):
            continuation.resume()
        }
    }
    
    public func logCurrentSettings() {
        addLog("⚙️ Aktuelle Einstellungen (geladen aus Speicher):", type: .info)
        addLog("   - Mono: \(settings.isMono ? "Ja" : "Nein")", type: .info)
        addLog("   - Bitrate: \(settings.bitrate)", type: .info)
        addLog("   - Abtastrate: \(settings.sampleRate) Hz", type: .info)
        addLog("   - Max Duration: \(settings.maxDurationHours == nil ? "Unlimitiert" : "\(settings.maxDurationHours!) Std")", type: .info)
        addLog("   - Parallel Mode: \(settings.useParallelEncoding ? "Aktiviert" : "Deaktiviert")", type: .info)
    }

    public func initSegmentProgress(index: Int, filename: String, runID: UUID? = nil) {
        if let runID, !isCurrentConversion(runID) { return }
        segmentProgress[index] = SegmentStatus(filename: filename, progress: 0.0)
    }

    public func updateSegmentProgress(index: Int, progress: Double, runID: UUID? = nil) {
        if let runID, !isCurrentConversion(runID) { return }
        if var status = segmentProgress[index] {
            // Fortschrittsmeldungen mehrerer Worker treffen nicht zwingend in
            // derselben Reihenfolge auf dem Main Actor ein. Ein Segment darf
            // deshalb sichtbar nie rückwärts laufen.
            status.progress = max(status.progress, progress)
            segmentProgress[index] = status
        }
    }

    public func forceCloseOverlay() {
        resetSession()
    }

    public func resetSession() {
        invalidateImportWork()
        self.audioFiles.removeAll()
        self.showOverlay = false
        self.isConverting = false
        self.progress = 0.0
        self.conversionStatus = "Bereit"
        self.lastConversionSucceeded = nil
        self.eventLogs = []
        self.logString = ""
        self.segmentProgress = [:]
    }

    /// Kennung der zuletzt gestarteten Info-Abfrage. Klickt der Nutzer schnell
    /// nacheinander auf mehrere Dateien, laufen mehrere mediainfo-Prozesse
    /// parallel — ohne diese Kennung könnte ein langsamer, veralteter Lauf das
    /// Ergebnis der zuletzt angefragten Datei überschreiben.
    /// Nur auf dem Main Actor lesen/schreiben.
    private var infoRequestToken = UUID()

    /// Nur auf dem Main Actor aufrufen (setzt @Published-State).
    public func fetchRawMediaInfo(for file: AudioFile) {
        let token = UUID()
        self.infoRequestToken = token
        self.isFetchingInfo = true
        self.selectedFileInfoText = "Lade Informationen..."
        self.showInfoSheet = true

        let fileURL = file.url
        Task { [weak self] in
            // Gebündeltes mediainfo bevorzugen (getBinaryURL: Bundle -> PATH ->
            // Homebrew-Fallback). Vorher fest verdrahtete Homebrew-Pfade ließen
            // den Info-Dialog in der verteilten App ohne Homebrew scheitern,
            // obwohl mediainfo mitgeliefert wird.
            let text = await Task.detached {
                Self.readRawMediaInfo(for: fileURL)
            }.value
            self?.updateInfoText(text, token: token)
        }
    }

    private func updateInfoText(_ text: String, token: UUID) {
        // Veraltete Antwort verwerfen: Der Nutzer hat inzwischen die Info
        // einer anderen Datei angefragt, deren Ergebnis gewinnen muss.
        guard token == infoRequestToken else { return }
        selectedFileInfoText = text
        isFetchingInfo = false
    }

    private nonisolated static func readRawMediaInfo(for fileURL: URL) -> String {
        guard let miURL = FFmpegWrapper.getBinaryURL(name: "mediainfo") else {
            return "❌ MediaInfo wurde auf diesem System nicht gefunden."
        }
        switch FFmpegWrapper.runCapturedProcess(
            executableURL: miURL,
            arguments: [fileURL.path],
            timeout: 10
        ) {
        case .completed(let status, let data) where status == 0:
            guard !data.isEmpty else {
                return "MediaInfo hat keine Informationen geliefert."
            }
            return decodeMediaInfoText(from: data) ?? "Dekodierung fehlgeschlagen."
        case .timedOut:
            return "MediaInfo wurde nach 10 Sekunden beendet."
        case .cancelled:
            return "MediaInfo-Abfrage wurde abgebrochen."
        case .completed(let status, _):
            return "MediaInfo endete mit Exit-Code \(status)."
        case .failed(let reason):
            return "Fehler: \(reason)"
        }
    }

    nonisolated static func decodeMediaInfoText(from data: Data) -> String? {
        let bytes = [UInt8](data.prefix(2))
        let hasUTF16BOM = bytes == [0xFF, 0xFE] || bytes == [0xFE, 0xFF]
        let encodings: [String.Encoding] = hasUTF16BOM
            ? [.utf16, .utf8, .macOSRoman, .isoLatin1]
            : [.utf8, .macOSRoman, .isoLatin1]
        return encodings.lazy.compactMap { String(data: data, encoding: $0) }.first
    }

    public var totalDuration: TimeInterval { audioFiles.reduce(0) { $0 + $1.duration } }

    public func clearMetadata() {
        self.title = ""; self.author = ""; self.genre = "Hörbuch"
        self.coverImage = nil; self.coverPath = nil; self.embeddedCoverData = nil
        self.isCoverSuppressed = false
        self.titleCandidates = []; self.authorCandidates = []
        self.showSelectionUI = false
        invalidateArtworkWork()
    }

    /// Markiert einen neuen GUI-Import. Langsame Antworten eines vorherigen
    /// Datei-/Ordner-Drops verlieren damit sofort ihre Schreibberechtigung.
    /// Nur auf dem Main Actor aufrufen.
    public func beginImport(expectedItemCount: Int = 1) -> ImportToken {
        // Derselbe Context besitzt Swift-Tasks und externe Analyseprozesse. Ein
        // neuer Drop beendet damit die noch laufende Arbeit seines Vorgängers.
        preparationCoordinator.begin()
        importGeneration = UUID()
        pendingImportOperations = max(0, expectedItemCount)
        isImporting = pendingImportOperations > 0
        importErrorMessage = nil
        lastImportFailures = []
        pendingImportAudioFiles = []
        pendingImportImageURLs = []
        pendingImportArtwork = nil
        pendingImportWarnings = []
        pendingImportFailures = []
        pendingImportWasCancelled = false
        pendingImportFolderURL = nil
        pendingImportCanRepresentFolder = expectedItemCount == 1
        cliSourceFolderURL = nil
        cliRepresentedFileIDs = []
        cliRepresentedChapterTitles = [:]
        invalidateArtworkWork()
        return ImportToken(generation: importGeneration, coverRevision: coverRevision)
    }

    /// Meldet genau einen Provider/Scan als abgeschlossen. Erst wenn alle Teile
    /// desselben Drops übernommen sind, beginnt eine einzige Metadatenabfrage.
    public func finishImport(_ token: ImportToken) async {
        guard isCurrentImport(token), pendingImportOperations > 0 else { return }
        pendingImportOperations -= 1
        guard pendingImportOperations == 0 else { return }
        if pendingImportWasCancelled {
            isImporting = false
            clearPendingImportBatch()
            return
        }
        if !pendingImportFailures.isEmpty {
            pendingImportWarnings.forEach { addLog($0) }
            pendingImportFailures.forEach { addLog($0.logMessage, type: .highlight) }
            lastImportFailures = pendingImportFailures
            importErrorMessage = Self.importFailureMessage(pendingImportFailures)
            isImporting = false
            clearPendingImportBatch()
            return
        }

        let stagedAudioFiles = pendingImportAudioFiles
        let stagedImageURLs = pendingImportImageURLs
        let stagedArtwork = pendingImportArtwork
        let stagedWarnings = pendingImportWarnings
        let sourceFolder = pendingImportCanRepresentFolder ? pendingImportFolderURL : nil
        clearPendingImportBatch()
        await applyScannedFolderContents(
            audioFiles: stagedAudioFiles,
            imageURLs: stagedImageURLs,
            embeddedArtwork: stagedArtwork,
            warnings: stagedWarnings,
            importToken: token,
            sourceFolderForCLI: sourceFolder
        )
        if (title.isEmpty || author.isEmpty), let first = audioFiles.first {
            await importGlobalMetadata(from: first, importToken: token)
            await finishMetadataImport(token: token, sourceFileID: first.id)
        } else {
            isImporting = false
        }
    }

    private func finishMetadataImport(token: ImportToken, sourceFileID: UUID) async {
        guard isCurrentImport(token) else { return }
        // Wurde gerade die Datei entfernt, deren Tags gelesen wurden, darf ihr
        // Ergebnis nicht gewinnen. Ein verbleibendes erstes Kapitel bekommt
        // genau einen neuen Versuch.
        if !audioFiles.contains(where: { $0.id == sourceFileID }),
           let first = audioFiles.first {
            await importGlobalMetadata(from: first, importToken: token)
            await finishMetadataImport(token: token, sourceFileID: first.id)
            return
        }
        isImporting = false
    }

    private func invalidateImportWork() {
        _ = preparationCoordinator.cancel()
        importGeneration = UUID()
        pendingImportOperations = 0
        isImporting = false
        cliSourceFolderURL = nil
        cliRepresentedFileIDs = []
        cliRepresentedChapterTitles = [:]
        clearPendingImportBatch()
        invalidateArtworkWork()
    }

    private func clearPendingImportBatch() {
        pendingImportAudioFiles = []
        pendingImportImageURLs = []
        pendingImportArtwork = nil
        pendingImportWarnings = []
        pendingImportFailures = []
        pendingImportWasCancelled = false
        pendingImportFolderURL = nil
        pendingImportCanRepresentFolder = false
    }

    private static func importFailureMessage(_ failures: [AudioImportFailure]) -> String {
        let details = failures.map {
            "• \($0.sourceURL.lastPathComponent): \($0.message)"
        }.joined(separator: "\n")
        return "Der Import wurde vollständig verworfen, damit kein Hörbuch mit fehlenden Kapiteln entsteht.\n\n\(details)"
    }

    private func invalidateArtworkWork() {
        artworkRequest = UUID()
        isPreparingArtwork = false
    }

    private func isCurrentImport(_ token: ImportToken) -> Bool {
        token.generation == importGeneration
    }

    private func addImportLog(_ message: String, token: ImportToken) {
        guard isCurrentImport(token) else { return }
        addLog(message)
    }

    /// Der GUI→CLI-Handoff ist nur ehrlich, wenn die aktuelle Dateiliste exakt
    /// aus einem einzigen Ordner-Import stammt. Einzeldateien oder gemischte
    /// Imports kann die ordnerbasierte CLI nicht identisch darstellen.
    public var cliFolderIfRepresentable: URL? {
        let currentIDs = Set(audioFiles.map(\.id))
        let chapterTitlesStillMatch = audioFiles.allSatisfy {
            cliRepresentedChapterTitles[$0.id] == $0.chapterTitle
        }
        guard !currentIDs.isEmpty,
              currentIDs == cliRepresentedFileIDs,
              chapterTitlesStillMatch else { return nil }
        return cliSourceFolderURL
    }
    
    /// `skipCoverExtraction`: überspringt die (schwere, AVAsset-lastige) Suche nach
    /// eingebettetem Cover. Wird vom Ordner-Pfad genutzt, der das Cover bereits beim
    /// Hintergrund-Scan (`scanFolder`) ermittelt hat — so läuft die Suche nicht ein
    /// zweites Mal, und vor allem nicht auf dem Main-Thread.
    public func processIncomingFiles(
        _ newFiles: [AudioFile],
        skipCoverExtraction: Bool = false,
        importToken: ImportToken? = nil,
        sourceFolderForCLI: URL? = nil
    ) async {
        if let importToken, !isCurrentImport(importToken) { return }
        // `append(contentsOf: [])` und sogar `sort()` lösen `didSet` aus. Bei
        // weiterhin leerer Liste sähe das sonst wie ein ausdrückliches
        // „Alle löschen“ aus und würde den gemeinsamen Mehrfach-Drop entwerten.
        guard !newFiles.isEmpty else { return }
        let canRepresentFolder = audioFiles.isEmpty && sourceFolderForCLI != nil
        let sourceCount = Set(newFiles.map { $0.sourceURL.standardizedFileURL.path }).count
        let sourceLabel = sourceCount == 1 ? "Audiodatei" : "Audiodateien"
        if sourceCount == newFiles.count {
            addLog("📥 Importiere \(sourceCount) \(sourceLabel)...")
        } else {
            addLog("📥 Importiere \(sourceCount) \(sourceLabel) mit \(newFiles.count) Kapiteln...")
        }
        let deduplicated = Self.deduplicateAudioFiles(audioFiles + newFiles)
        self.audioFiles = deduplicated.files.sorted(by: Self.audioFileComesBefore)
        for duplicate in deduplicated.discardedSources {
            addLog(
                "⚠️ \(duplicate.discarded.lastPathComponent) und \(duplicate.kept.lastPathComponent) "
                + "lesen dieselbe Audiodatei; importiert wird nur \(duplicate.kept.lastPathComponent)."
            )
        }
        if canRepresentFolder, let sourceFolderForCLI {
            cliSourceFolderURL = sourceFolderForCLI
            cliRepresentedFileIDs = Set(audioFiles.map(\.id))
            cliRepresentedChapterTitles = Dictionary(uniqueKeysWithValues: audioFiles.map { ($0.id, $0.chapterTitle) })
        } else {
            cliSourceFolderURL = nil
            cliRepresentedFileIDs = []
            cliRepresentedChapterTitles = [:]
        }
        if !skipCoverExtraction && !isCoverSuppressed && coverImage == nil && coverPath == nil {
            // Artwork-Suche (schwere AVAsset-Zugriffe) in den Hintergrund — beim
            // Einzeldatei-Drop lief sie sonst synchron auf dem Main-Thread und
            // ließ die UI haken (der Ordner-Pfad erledigt das bereits im
            // Hintergrund-Scan, siehe skipCoverExtraction).
            let request = UUID()
            artworkRequest = request
            let expectedCoverRevision = coverRevision
            // Bei einem Multi-Datei-Drop können mehrere Provider kurz
            // nacheinander ankommen. Die jeweils neueste Suche umfasst deshalb
            // die komplette aktuelle Liste und kann Artwork aus einem früher
            // gelieferten Provider weiterhin finden.
            let filesToSearch = audioFiles
            let importedFileIDs = Set(filesToSearch.map(\.id))
            isPreparingArtwork = true
            Task { [weak self] in
                var foundArtwork: (image: NSImage, data: Data)?
                for file in Self.uniqueArtworkCandidates(filesToSearch) {
                    if let artworkData = await AudioFile.extractEmbeddedArtwork(from: file.url) {
                        // Manche Container deklarieren beliebige Binärdaten als
                        // Artwork. Nur tatsächlich dekodierbare Bilder dürfen in
                        // den späteren ffmpeg-Auftrag gelangen.
                        if let image = NSImage(data: artworkData) {
                            foundArtwork = (image, artworkData)
                            break
                        }
                    }
                }
                guard let self,
                      self.artworkRequest == request else { return }
                // Der aktuelle Request ist in jedem Fall beendet. Weitere
                // Guards entscheiden nur noch, ob sein Ergebnis anwendbar ist.
                self.isPreparingArtwork = false
                guard
                      self.coverRevision == expectedCoverRevision,
                      !self.isCoverSuppressed,
                      importToken.map(self.isCurrentImport) ?? true,
                      importedFileIDs.isSubset(of: Set(self.audioFiles.map(\.id))) else { return }
                // Ein zwischenzeitlich manuell gesetztes Cover gewinnt.
                guard self.coverImage == nil, self.coverPath == nil,
                      let foundArtwork else { return }
                self.coverImage = foundArtwork.image
                self.coverPath = nil
                self.embeddedCoverData = foundArtwork.data
            }
        }
        // GUI-Drops sammeln erst alle Provider und starten danach in
        // `finishImport` genau eine Metadatenabfrage. Der erwartete CLI-Pfad hat
        // keinen Import-Token und löst die Abfrage hier direkt aus.
        if importToken == nil, (title.isEmpty || author.isEmpty) {
            if let first = audioFiles.first {
                await importGlobalMetadata(from: first, importToken: importToken)
            }
        }
    }

    /// Vergleicht den gesamten sichtbaren Pfad komponentenweise in natürlicher
    /// Finder-Reihenfolge. Dadurch bleiben `CD1/01`, `CD1/02`, `CD2/01` und
    /// `CD2/02` gruppiert. Kapitel derselben Quelldatei folgen erst danach ihrer
    /// Startzeit.
    private static func audioFileComesBefore(_ left: AudioFile, _ right: AudioFile) -> Bool {
        if left.sourceURL == right.sourceURL {
            return left.startTime < right.startTime
        }

        let leftComponents = left.sourceURL.standardizedFileURL.pathComponents
        let rightComponents = right.sourceURL.standardizedFileURL.pathComponents
        for (leftComponent, rightComponent) in zip(leftComponents, rightComponents) {
            let natural = leftComponent.localizedStandardCompare(rightComponent)
            if natural != .orderedSame { return natural == .orderedAscending }
            // `localizedStandardCompare` kann unterschiedliche Schreibweisen
            // gleich behandeln. Der literale Tiebreak erhält eine stabile,
            // strenge Reihenfolge, ohne vorzeitig die Kapitelzeit zu benutzen.
            let literal = leftComponent.compare(rightComponent, options: .literal)
            if literal != .orderedSame { return literal == .orderedAscending }
        }
        if leftComponents.count != rightComponents.count {
            return leftComponents.count < rightComponents.count
        }
        return left.url.path < right.url.path
    }

    private func importGlobalMetadata(
        from file: AudioFile,
        importToken: ImportToken?
    ) async {
        let preparation = currentPreparationContext()
        let fileURL = file.url
        let candidates = await Task.detached {
            var result: (titles: [TagCandidate], authors: [TagCandidate])?
            if preparation?.isCancelled != true,
               let miURL = FFmpegWrapper.getBinaryURL(name: "mediainfo") {
                let processResult = FFmpegWrapper.runCapturedProcess(
                    executableURL: miURL,
                    arguments: ["--Output=JSON", fileURL.path],
                    context: preparation,
                    timeout: 10
                )
                if case .completed(let status, let data) = processResult,
                   status == 0,
                   preparation?.isCancelled != true,
                   let general = Self.decodeMediaInfoGeneralTrack(from: data) {
                    result = Self.metadataCandidates(from: general)
                }
            }
            return result
        }.value

        guard importToken.map(isCurrentImport) ?? true,
              importToken == nil || audioFiles.contains(where: { $0.id == file.id }),
              preparation?.isCancelled != true else {
            return
        }
        guard let candidates else {
            // Kandidaten gehören immer genau zum aktuellen Import. Andernfalls
            // könnte die Auswahl nach einem MediaInfo-Fehler Werte des vorherigen
            // Buchs anbieten.
            titleCandidates = []
            authorCandidates = []
            showSelectionUI = importToken != nil
            return
        }
        titleCandidates = candidates.titles
        authorCandidates = candidates.authors
        // Ohne Import-Token läuft der headless CLI-Pfad (siehe
        // `processIncomingFiles`) — dort gibt es keine Auswahl-UI.
        let resolution = Self.resolveMetadata(
            currentTitle: title,
            currentAuthor: author,
            titleCandidates: candidates.titles,
            authorCandidates: candidates.authors,
            allowsSelectionUI: importToken != nil
        )
        title = resolution.title
        author = resolution.author
        showSelectionUI = resolution.shouldShowSelection
    }

    nonisolated static func decodeMediaInfoGeneralTrack(from data: Data) -> [String: Any]? {
        // Pro Zeichensatz erst den JSON-Parse prüfen. MacRoman/Latin-1 können
        // fast jede Bytefolge als Text darstellen und dürfen einen später
        // tatsächlich passenden UTF-16-Versuch nicht vorzeitig verdrängen.
        for encoding in [String.Encoding.utf8, .utf16, .macOSRoman, .isoLatin1] {
            guard let text = String(data: data, encoding: encoding),
                  let start = text.firstIndex(of: "{"),
                  let end = text.lastIndex(of: "}"),
                  start <= end,
                  let jsonData = String(text[start...end]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: jsonData),
                  let root = object as? [String: Any],
                  let media = root["media"] as? [String: Any],
                  let tracks = media["track"] as? [[String: Any]],
                  let general = tracks.first(where: { $0["@type"] as? String == "General" }) else {
                continue
            }
            return general
        }
        return nil
    }

    private nonisolated static func metadataCandidates(
        from general: [String: Any]
    ) -> (titles: [TagCandidate], authors: [TagCandidate]) {
        func value(for key: String) -> String? {
            general[key] as? String ?? (general[key] as? [String])?.first
        }
        var titles: [TagCandidate] = []
        var authors: [TagCandidate] = []
        if let album = value(for: "Album") {
            titles.append(TagCandidate(type: "MediaInfo", key: "Album", value: album))
        }
        if let title = value(for: "Title") {
            titles.append(TagCandidate(type: "MediaInfo", key: "Title", value: title))
        }
        if let performer = value(for: "Performer") {
            authors.append(TagCandidate(type: "MediaInfo", key: "Performer", value: performer))
        }
        if let albumPerformer = value(for: "Album_Performer") {
            authors.append(TagCandidate(type: "MediaInfo", key: "Album_Performer", value: albumPerformer))
        }
        return (titles, authors)
    }

    /// `allowsSelectionUI: false` ist der headless-Pfad (CLI): Bei mehrdeutigen
    /// Kandidaten gewinnt der erste in Listenreihenfolge — also Album vor Title
    /// bzw. Performer vor Album_Performer (siehe `metadataCandidates`) — statt
    /// den Wert leer zu lassen und auf eine SwiftUI-Auswahl zu warten, die die
    /// CLI nie anzeigt. Das stellt die frühere Erst-Kandidaten-Priorität wieder
    /// her; die GUI (`true`) öffnet weiterhin die manuelle Auswahl.
    nonisolated static func resolveMetadata(
        currentTitle: String,
        currentAuthor: String,
        titleCandidates: [TagCandidate],
        authorCandidates: [TagCandidate],
        allowsSelectionUI: Bool = true
    ) -> MetadataResolution {
        func resolve(current: String, candidates: [TagCandidate]) -> (String, Bool) {
            guard current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return (current, false)
            }
            let values = candidates
                .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let uniqueValues = Array(Set(values)).sorted()
            if uniqueValues.count == 1 { return (uniqueValues[0], false) }
            guard allowsSelectionUI else {
                // Headless: erster nichtleerer Kandidat oder unverändert leer.
                return (values.first ?? current, false)
            }
            return (current, true)
        }

        let resolvedTitle = resolve(current: currentTitle, candidates: titleCandidates)
        let resolvedAuthor = resolve(current: currentAuthor, candidates: authorCandidates)
        return MetadataResolution(
            title: resolvedTitle.0,
            author: resolvedAuthor.0,
            shouldShowSelection: resolvedTitle.1 || resolvedAuthor.1
        )
    }

    /// Ergebnis eines Ordner-Scans. Enthält keinen `@Published`-State und kann
    /// deshalb sicher von der Audioanalyse zum Main Actor übertragen werden.
    public struct ScannedFolder: Sendable {
        public var folderURL: URL
        public var audioFiles: [AudioFile]
        public var imageURLs: [URL]
        public var embeddedArtwork: Data?
        public var warnings: [String]
        public var failures: [AudioImportFailure]
        public var wasCancelled: Bool

        public init(
            folderURL: URL,
            audioFiles: [AudioFile],
            imageURLs: [URL],
            embeddedArtwork: Data?,
            warnings: [String] = [],
            failures: [AudioImportFailure] = [],
            wasCancelled: Bool = false
        ) {
            self.folderURL = folderURL
            self.audioFiles = audioFiles
            self.imageURLs = imageURLs
            self.embeddedArtwork = embeddedArtwork
            self.warnings = warnings
            self.failures = failures
            self.wasCancelled = wasCancelled
        }
    }

    /// Schwerer Teil des Ordner-Imports: rekursiv scannen, m4b-Kapitel via ffmpeg
    /// extrahieren, Dauern/eingebettetes Artwork lesen. Rührt **keinen**
    /// `@Published`-State an. Die AVFoundation-Aufrufe suspendieren asynchron;
    /// der Dateisystem- und ffmpeg-Anteil läuft außerhalb des Main Actors.
    public nonisolated func scanFolder(
        _ url: URL,
        importToken: ImportToken? = nil
    ) async -> ScannedFolder {
        var foundAudio: [AudioFile] = []
        var foundImages: [URL] = []
        var warnings: [String] = []
        var analysisFailures: [AudioImportFailure] = []
        let discovery = Self.discoverFileURLs(
            in: url,
            cancellationRequested: { preparationCancellationRequested() }
        )
        if let failure = discovery.failureDescription {
            return ScannedFolder(
                folderURL: url,
                audioFiles: [],
                imageURLs: [],
                embeddedArtwork: nil,
                warnings: ["❌ Ordner konnte nicht vollständig gelesen werden: \(failure)"],
                failures: [AudioImportFailure(sourceURL: url, reason: .analysisFailed)]
            )
        }
        let discovered = discovery.files
        let supported = discovered.filter { $0.kind != .unsupported }
        let deduplicated = Self.deduplicateFoundFiles(supported)
        var loggedTargets = Set<String>()
        for discarded in deduplicated.discarded {
            let target = discarded.resolved.standardizedFileURL.path
            guard loggedTargets.insert(target).inserted else { continue }
            let kept = deduplicated.files.first {
                $0.resolved.standardizedFileURL.path == target
            }
            warnings.append(
                "⚠️ Mehrere Ordner-Einträge zeigen auf \(discarded.resolved.lastPathComponent); "
                + "importiert wird nur \(kept?.source.lastPathComponent ?? discarded.source.lastPathComponent)."
            )
        }

        for found in deduplicated.files {
            if preparationCancellationRequested() { break }
            switch found.kind {
            case .audio:
                let loaded = await loadAudioFiles(from: found, importToken: importToken)
                foundAudio.append(contentsOf: loaded.files)
                warnings.append(contentsOf: loaded.warnings)
                if loaded.wasCancelled {
                    return ScannedFolder(
                        folderURL: url,
                        audioFiles: [],
                        imageURLs: [],
                        embeddedArtwork: nil,
                        warnings: warnings,
                        wasCancelled: true
                    )
                }
                if let failure = loaded.failures.first {
                    // Alle weiteren Dateien trotzdem analysieren, damit GUI und
                    // CLI in einem Lauf die vollständige Fehlerliste nennen.
                    analysisFailures.append(failure)
                }
            case .image:
                foundImages.append(found.readURL)
            case .unsupported:
                break
            }
        }
        var embedded: Data? = nil
        for audioFile in Self.uniqueArtworkCandidates(foundAudio) {
            if preparationCancellationRequested() { break }
            if let artworkData = await AudioFile.extractEmbeddedArtwork(from: audioFile.url) {
                if preparationCancellationRequested() { break }
                if NSImage(data: artworkData) != nil {
                    embedded = artworkData
                    break
                }
            }
        }
        return ScannedFolder(
            folderURL: url,
            audioFiles: foundAudio,
            imageURLs: foundImages,
            embeddedArtwork: embedded,
            warnings: warnings,
            failures: analysisFailures
        )
    }

    /// Löst genau einen Dateipfad nach denselben Regeln wie der Ordnerscan auf.
    /// Verzeichnis- und defekte Symlinks sind keine importierbaren Dateien.
    public nonisolated static func foundFile(at url: URL) -> FoundFile? {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return nil }
        if values.isRegularFile == true {
            return FoundFile(source: url, resolved: url)
        }
        guard values.isSymbolicLink == true else { return nil }
        let resolved = url.resolvingSymlinksInPath()
        guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?
            .isRegularFile == true else { return nil }
        return FoundFile(source: url, resolved: resolved)
    }

    /// Entfernt physische Dubletten. Ein bewusst benannter Symlink gewinnt
    /// gegen die danebenliegende Zieldatei; bei mehreren Links bleibt der erste
    /// Enumerator-Treffer erhalten.
    nonisolated static func deduplicateFoundFiles(
        _ files: [FoundFile]
    ) -> (files: [FoundFile], discarded: [FoundFile]) {
        var kept: [FoundFile] = []
        var indexByTarget: [String: Int] = [:]
        var discarded: [FoundFile] = []
        for file in files {
            let target = file.resolved.standardizedFileURL.path
            guard let index = indexByTarget[target] else {
                indexByTarget[target] = kept.count
                kept.append(file)
                continue
            }
            if file.isSymbolicLink, !kept[index].isSymbolicLink {
                discarded.append(kept[index])
                kept[index] = file
            } else {
                discarded.append(file)
            }
        }
        return (kept, discarded)
    }

    /// Dedupliziert auch über getrennt eintreffende Drop-Provider hinweg. Alle
    /// Kapitel derselben Containerdatei bleiben als Gruppe erhalten; ein
    /// sichtbarer Symlink gewinnt wie beim Ordnerscan gegen das direkte Ziel.
    nonisolated static func deduplicateAudioFiles(
        _ files: [AudioFile]
    ) -> (files: [AudioFile], discardedSources: [(discarded: URL, kept: URL)]) {
        var selectedSourceByTarget: [String: URL] = [:]
        for file in files {
            let target = file.url.standardizedFileURL.path
            let source = file.sourceURL.standardizedFileURL
            guard let selected = selectedSourceByTarget[target] else {
                selectedSourceByTarget[target] = source
                continue
            }
            let selectedIsLink = selected.path != target
            let candidateIsLink = source.path != target
            if candidateIsLink && !selectedIsLink {
                selectedSourceByTarget[target] = source
            }
        }

        var reportedDiscardedSources = Set<String>()
        var seenSegments = Set<String>()
        var discardedSources: [(discarded: URL, kept: URL)] = []
        let kept = files.filter { file in
            let target = file.url.standardizedFileURL.path
            guard let selected = selectedSourceByTarget[target] else { return false }
            let source = file.sourceURL.standardizedFileURL
            if source != selected {
                let reportKey = "\(target)\u{0}\(source.path)"
                if reportedDiscardedSources.insert(reportKey).inserted {
                    discardedSources.append((discarded: source, kept: selected))
                }
                return false
            }
            // Derselbe Provider darf dasselbe Kapitel nicht mehrfach liefern.
            // Start und Dauer gehören zum Schlüssel, damit unterschiedliche
            // Kapitel desselben m4b/mp4-Containers erhalten bleiben.
            let segmentKey = "\(target)\u{0}\(source.path)\u{0}"
                + "\(file.startTime.bitPattern)\u{0}\(file.duration.bitPattern)"
            guard seenSegments.insert(segmentKey).inserted else {
                let reportKey = "duplicate\u{0}\(segmentKey)"
                if reportedDiscardedSources.insert(reportKey).inserted {
                    discardedSources.append((discarded: source, kept: selected))
                }
                return false
            }
            return true
        }
        return (kept, discardedSources)
    }

    /// Ein m4b liefert mehrere Kapitel mit derselben physischen URL. Seine
    /// eingebetteten Metadaten müssen trotzdem nur einmal gelesen werden.
    nonisolated static func uniqueArtworkCandidates(_ files: [AudioFile]) -> [AudioFile] {
        var seen = Set<String>()
        return files.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
    }

    /// `FileManager.DirectoryEnumerator` ist absichtlich nicht über einen
    /// asynchronen Aufruf hinweg haltbar. Die Dateiliste wird deshalb synchron
    /// aufgebaut, prüft den laufbezogenen Abbruch aber vor und nach jedem
    /// `nextObject()`, damit auch ein großer Ordnerscan sofort enden kann.
    nonisolated static func discoverFileURLs(
        in url: URL,
        cancellationRequested: () -> Bool = { false }
    ) -> FileDiscoveryResult {
        guard !cancellationRequested() else {
            return FileDiscoveryResult(files: [], failureDescription: nil)
        }
        let failureRecorder = DirectoryScanFailureRecorder()
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { failedURL, error in
                failureRecorder.record(url: failedURL, error: error)
                // Bei einem Lesefehler wäre jedes Teilergebnis potenziell ein
                // Hörbuch mit fehlenden Kapiteln. Deshalb sofort stoppen.
                return false
            }
        ) else {
            return FileDiscoveryResult(
                files: [],
                failureDescription: "\(url.path): Ordner kann nicht gelesen werden."
            )
        }

        var files: [FoundFile] = []
        while !cancellationRequested() {
            guard let item = enumerator.nextObject() else { break }
            guard !cancellationRequested() else { break }
            guard let fileURL = item as? URL else { continue }
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
            } catch {
                failureRecorder.record(url: fileURL, error: error)
                break
            }

            if values.isRegularFile == true {
                files.append(FoundFile(source: fileURL, resolved: fileURL))
                continue
            }
            guard values.isSymbolicLink == true else { continue }
            // Verzeichnis-Symlinks nie als Rekursionsweg verwenden. Ein
            // Dateisymlink wird dagegen bis zur regulären Zieldatei aufgelöst;
            // AVFoundation liefert für den Linkpfad selbst nicht zuverlässig
            // Dauer und Metadaten. Der LINKNAME bleibt trotzdem erhalten: er
            // bestimmt Reihenfolge und Kapiteltitel, sonst gäbe eine Sammlung
            // aus `01.wav -> Original-B.wav`, `02.wav -> Original-A.wav` die
            // vom Nutzer festgelegte Reihenfolge auf (Review-Fund 2026-08-17).
            enumerator.skipDescendants()
            if let found = foundFile(at: fileURL) { files.append(found) }
        }
        if let failure = failureRecorder.snapshot() {
            return FileDiscoveryResult(files: [], failureDescription: failure)
        }
        return FileDiscoveryResult(files: files, failureDescription: nil)
    }

    nonisolated static func recursiveFileURLs(
        in url: URL,
        cancellationRequested: () -> Bool = { false }
    ) -> [FoundFile] {
        discoverFileURLs(in: url, cancellationRequested: cancellationRequested).files
    }

    /// Stellt einen Provider-Beitrag bis zum Abschluss des gesamten Drops
    /// zurück. Erst `finishImport` übernimmt die gemeinsame Liste oder verwirft
    /// sie bei einem einzigen Analysefehler vollständig.
    public func stageAudioLoadResult(
        _ result: AudioLoadResult,
        importToken: ImportToken
    ) {
        guard isCurrentImport(importToken) else { return }
        switch result {
        case .success(let files, let warnings):
            pendingImportAudioFiles.append(contentsOf: files)
            pendingImportWarnings.append(contentsOf: warnings)
        case .failure(let failure):
            pendingImportFailures.append(failure)
        case .cancelled:
            pendingImportWasCancelled = true
        case .skipped:
            break
        }
    }

    public func stageScannedFolder(
        _ scanned: ScannedFolder,
        importToken: ImportToken
    ) {
        guard isCurrentImport(importToken) else { return }
        pendingImportAudioFiles.append(contentsOf: scanned.audioFiles)
        pendingImportImageURLs.append(contentsOf: scanned.imageURLs)
        if pendingImportArtwork == nil { pendingImportArtwork = scanned.embeddedArtwork }
        pendingImportWarnings.append(contentsOf: scanned.warnings)
        pendingImportFailures.append(contentsOf: scanned.failures)
        pendingImportWasCancelled = pendingImportWasCancelled || scanned.wasCancelled
        if pendingImportCanRepresentFolder {
            pendingImportFolderURL = scanned.folderURL
        }
    }

    /// Leichter Teil: das Scan-Ergebnis in den Main-Actor-isolierten
    /// `@Published`-State übernehmen.
    public func applyScannedFolder(
        _ scanned: ScannedFolder,
        importToken: ImportToken? = nil
    ) async {
        if AudioFile.taskCancellationRequested() { return }
        if let importToken, !isCurrentImport(importToken) { return }
        guard !scanned.wasCancelled else { return }
        guard scanned.failures.isEmpty else {
            scanned.warnings.forEach { addLog($0) }
            scanned.failures.forEach { addLog($0.logMessage, type: .highlight) }
            lastImportFailures = scanned.failures
            importErrorMessage = Self.importFailureMessage(scanned.failures)
            return
        }
        await applyScannedFolderContents(
            audioFiles: scanned.audioFiles,
            imageURLs: scanned.imageURLs,
            embeddedArtwork: scanned.embeddedArtwork,
            warnings: scanned.warnings,
            importToken: importToken,
            sourceFolderForCLI: scanned.folderURL
        )
    }

    private func applyScannedFolderContents(
        audioFiles: [AudioFile],
        imageURLs: [URL],
        embeddedArtwork: Data?,
        warnings: [String],
        importToken: ImportToken?,
        sourceFolderForCLI: URL?
    ) async {
        for warning in warnings { addLog(warning) }
        let expectedCoverRevision = importToken?.coverRevision ?? coverRevision
        if coverRevision == expectedCoverRevision, !isCoverSuppressed,
           coverImage == nil, coverPath == nil,
           let artworkData = embeddedArtwork,
           let image = NSImage(data: artworkData) {
            coverImage = image
            coverPath = nil
            // Rohdaten merken (siehe processIncomingFiles): nur so landet ein
            // eingebettetes Cover ohne separate Bilddatei auch im Output.
            embeddedCoverData = artworkData
            isCoverSuppressed = false
        }
        // Cover-Suche nicht erneut (schon im Scan erledigt) — sonst liefe sie hier
        // auf dem Main-Thread über alle Dateien.
        await processIncomingFiles(
            audioFiles,
            skipCoverExtraction: true,
            importToken: importToken,
            sourceFolderForCLI: sourceFolderForCLI
        )
        if coverRevision == expectedCoverRevision,
           !isCoverSuppressed,
           !imageURLs.isEmpty,
           let url = findLargestImage(from: imageURLs) {
            selectCover(url: url)
        }
    }

    /// Vollständiger Ordner-Import für die CLI: Audioanalyse außerhalb des Main
    /// Actors, anschließend Übernahme und Metadatenauflösung auf Main.
    public func addFolder(_ url: URL) async {
        let scanned = await scanFolder(url)
        guard !preparationCancellationRequested() else { return }
        await applyScannedFolder(scanned)
    }

    private func findLargestImage(from urls: [URL]) -> URL? {
        var maxFileSize = -1; var largestURL: URL?
        for url in urls {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxFileSize {
                maxFileSize = size; largestURL = url
            }
        }
        return largestURL
    }

    @discardableResult
    public func selectCover(url: URL) -> Bool {
        // Auswahl bedeutet Besitz eines unveränderlichen Inhalts-Snapshots,
        // nicht nur Merken eines später erneut gelesenen Pfads. Dadurch kann ein
        // gelöschtes oder ausgetauschtes Bild zwischen Auswahl und Start weder
        // das ausdrücklich gewählte Cover verlieren noch fremde Daten einsetzen.
        guard let data = FFmpegWrapper.loadCoverSnapshot(at: url),
              let image = NSImage(data: data) else { return false }
        coverRevision &+= 1
        invalidateArtworkWork()
        self.coverImage = resizeImage(image, maxDimension: 2000); self.coverPath = url.path
        // Gewählte Datei hat Vorrang vor eingebettetem Artwork.
        self.embeddedCoverData = data
        self.isCoverSuppressed = false
        return true
    }

    public func removeCover() {
        coverRevision &+= 1
        invalidateArtworkWork()
        coverImage = nil
        coverPath = nil
        embeddedCoverData = nil
        isCoverSuppressed = true
    }

    private func resizeImage(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let size = image.size
        // Ungültige Bildmaße nicht skalieren (würde durch null teilen).
        guard size.width > 0, size.height > 0 else { return image }
        if size.width <= maxDimension && size.height <= maxDimension { return image }
        let ratio = size.width / size.height
        let newSize = ratio > 1 ? NSSize(width: maxDimension, height: maxDimension / ratio) : NSSize(width: maxDimension * ratio, height: maxDimension)
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize), from: .zero, operation: .copy, fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }

}

public struct AudioFile: Identifiable, Sendable {
    enum AudioTrackAvailability: Sendable {
        case available
        case missing
        case unreadable
        case cancelled
    }
    public let id = UUID()
    /// Physische Lese-URL: die reguläre Datei, aus der AVFoundation und ffmpeg
    /// lesen. Bei einem Symlink ist das dessen aufgelöstes Ziel.
    public let url: URL
    /// Logischer Quellpfad: der Pfad, unter dem der Nutzer die Datei sieht.
    /// Bei einem Symlink der Linkpfad, sonst gleich `url`. Reihenfolge und
    /// Fallback-Kapiteltitel folgen ihm, damit zwei Links auf dasselbe Ziel
    /// unterscheidbar bleiben (Review-Fund 2026-08-17).
    public let sourceURL: URL
    public let duration: TimeInterval
    public let startTime: TimeInterval
    public var chapterTitle: String
    public var name: String { sourceURL.lastPathComponent }

    /// Lädt Dauer und Kapiteltitel einer gewöhnlichen Datei. Für Symlinks
    /// muss der strukturierte `FoundFile`-Initializer benutzt werden.
    public init(url: URL) async {
        let analyzed = await Self.loadDurationAndTitle(readURL: url, visibleURL: url)
        self.url = url
        self.sourceURL = url
        self.startTime = 0
        self.duration = analyzed.duration
        self.chapterTitle = analyzed.title
    }

    /// Lädt aus der physischen Ziel-Datei, behält aber sichtbaren Namen und
    /// Fallback-Titel des Quellpfads bei.
    public init(foundFile: FoundFile) async {
        let analyzed = await Self.loadDurationAndTitle(
            readURL: foundFile.readURL,
            visibleURL: foundFile.source
        )
        self.url = foundFile.readURL
        self.sourceURL = foundFile.source
        self.startTime = 0
        self.duration = analyzed.duration
        self.chapterTitle = analyzed.title
    }

    public init(url: URL, startTime: TimeInterval, duration: TimeInterval,
                chapterTitle: String) {
        self.url = url
        self.sourceURL = url
        self.startTime = AudioFile.sanitizeDuration(startTime)
        self.duration = AudioFile.sanitizeDuration(duration)
        self.chapterTitle = chapterTitle
    }

    public init(foundFile: FoundFile, startTime: TimeInterval,
                duration: TimeInterval, chapterTitle: String) {
        self.url = foundFile.readURL
        self.sourceURL = foundFile.source
        self.startTime = AudioFile.sanitizeDuration(startTime)
        self.duration = AudioFile.sanitizeDuration(duration)
        self.chapterTitle = chapterTitle
    }

    /// Gemeinsame AVFoundation-Analyse für reguläre Dateien und Symlink-Ziele.
    /// CMTime-Werte werden an der Quelle auf endlich und nicht-negativ geklemmt;
    /// unlesbare oder abgebrochene Metadaten fallen auf den sichtbaren Namen zurück.
    private static func loadDurationAndTitle(
        readURL: URL,
        visibleURL: URL
    ) async -> (duration: TimeInterval, title: String) {
        let fallbackTitle = visibleURL.deletingPathExtension().lastPathComponent
        guard !taskCancellationRequested() else { return (0, fallbackTitle) }
        let asset = AVAsset(url: readURL)
        let loadedDuration = try? await asset.load(.duration)
        let duration = sanitizeDuration(loadedDuration.map(CMTimeGetSeconds) ?? 0)
        guard !taskCancellationRequested() else { return (duration, fallbackTitle) }
        let metadata = (try? await asset.load(.metadata)) ?? []
        guard !taskCancellationRequested() else { return (duration, fallbackTitle) }
        let title = await findRobustTag(for: "title", in: metadata) ?? fallbackTitle
        return (duration, title)
    }

    /// Prüft den Stream-Typ getrennt von der Gesamtdauer des Containers. Eine
    /// reine Videodatei kann eine positive Dauer haben, ist für `-map 0:a` aber
    /// keine gültige Hörbuchquelle.
    static func audioTrackAvailability(at url: URL) async -> AudioTrackAvailability {
        guard !taskCancellationRequested() else { return .cancelled }
        do {
            let tracks = try await AVAsset(url: url).loadTracks(withMediaType: .audio)
            guard !taskCancellationRequested() else { return .cancelled }
            return tracks.isEmpty ? .missing : .available
        } catch {
            return taskCancellationRequested() ? .cancelled : .unreadable
        }
    }

    /// Macht eine Sekundenangabe für Berechnungen sicher: NaN/Infinity/negativ → 0.
    static func sanitizeDuration(_ seconds: TimeInterval) -> TimeInterval {
        return (seconds.isFinite && seconds >= 0) ? seconds : 0
    }

    /// Wertet die strukturierte Task-Cancellation über `Task.checkCancellation`
    /// aus, ohne die absichtlich fehlertoleranten Audio-APIs werfend zu machen.
    static func taskCancellationRequested() -> Bool {
        do {
            try Task.checkCancellation()
            return false
        } catch {
            return true
        }
    }

    private static func findRobustTag(
        for tagName: String,
        in metadata: [AVMetadataItem]
    ) async -> String? {
        guard !taskCancellationRequested() else { return nil }
        if let commonItem = metadata.first(where: { $0.commonKey?.rawValue == tagName }) {
            let value = try? await commonItem.load(.stringValue)
            guard !taskCancellationRequested() else { return nil }
            if let value, !value.isEmpty {
                return value
            }
        }
        for item in metadata {
            guard !taskCancellationRequested() else { return nil }
            guard let key = item.key else { continue }
            let keyString = String(describing: key).lowercased()
            if keyString.contains(tagName.lowercased()) {
                let value = try? await item.load(.stringValue)
                guard !taskCancellationRequested() else { return nil }
                if let value, !value.isEmpty { return value }
            }
        }
        return nil
    }
}
