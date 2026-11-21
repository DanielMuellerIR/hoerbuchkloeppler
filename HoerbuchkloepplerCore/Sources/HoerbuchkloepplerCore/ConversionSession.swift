import Foundation
import Combine
import AppKit

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
        // Den unveränderlichen Prozessgruppen-Snapshot noch unter derselben
        // Sperre bilden wie die Besitzliste. Andernfalls könnte ein Worker den
        // inzwischen beendeten Wrapper abmelden und dessen noch laufende Kinder
        // vergessen, bevor der Hintergrund-Terminierer die Gruppe erfasst.
        let terminationRequest = ProcessTerminator.makeTerminationRequest(
            for: activeProcesses
        )
        let activeTaskCancellations = Array(taskCancellations.values)
        processes.removeAll()
        taskCancellations.removeAll()
        lock.unlock()
        activeTaskCancellations.forEach { $0() }
        ProcessTerminator.terminateInBackground(terminationRequest) {}
        return true
    }
}

/// Verwaltet genau einen Lauf mit Swift-Tasks und Werkzeugprozessen außerhalb
/// des Main Actors. Import und Dateiinfo verwenden getrennte Instanzen, damit
/// ihr jeweiliger Neustart nur die eigene Arbeit beendet.
private final class ToolProcessCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var current: PreparationContext?

    @discardableResult
    func begin() -> PreparationContext {
        let next = PreparationContext()
        lock.lock()
        let previous = current
        current = next
        lock.unlock()
        previous?.cancel()
        return next
    }

    func context() -> PreparationContext? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func cancel() -> Bool {
        // Auswahl und Abbruch desselben Contexts bilden eine atomare Aktion.
        // `begin()` darf nicht zwischen beides treten und einen neuen Lauf
        // einsetzen, den ein gleichzeitig eintreffendes Signal dann verfehlt.
        lock.lock()
        defer { lock.unlock() }
        return current?.cancel() ?? false
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
    case segmentReset(String?, ConversionPhase, UUID)
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
    nonisolated let importService = AudioImportService()
    @Published public var settings: AudioSettings { didSet { importService.workerLimit = settings.importWorkerLimit } }
    public init(settings: AudioSettings = SettingsManager.shared.loadSettings()) {
        self.settings = settings.normalized()
        importService.workerLimit = self.settings.importWorkerLimit
        let service = importService
        embeddedArtworkLoader = { url in await service.artwork(at: url) }
        conversionEventQueue.start { [weak self] event in
            self?.applyConversionEvent(event)
        }
    }
    
    @Published public internal(set) var audioFiles: [AudioFile] = []

    @Published public internal(set) var coverImage: NSImage?
    @Published public internal(set) var coverPath: String?
    @Published public private(set) var isPreparingArtwork = false
    /// Meldet bewusste Cover-Änderungen und das Ersetzen des Buchzustands.
    public var coverSelectionChanges: AnyPublisher<Void, Never> {
        coverSelectionDidChange.eraseToAnyPublisher()
    }
    /// Rohdaten eines eingebetteten Covers (aus einer Audiodatei extrahiert), das
    /// NICHT als separate Bilddatei vorliegt. Wird vor der Kodierung in eine
    /// temporäre Datei geschrieben, damit ffmpeg es einbetten kann — sonst ginge
    /// ein nur eingebettetes Cover im Output verloren.
    public internal(set) var embeddedCoverData: Data?
    private var importGeneration = UUID()
    private var artworkRequest = UUID()
    private var artworkTask: Task<Void, Never>?
    private var coverRevision: UInt = 0
    private let coverSelectionDidChange = PassthroughSubject<Void, Never>()
    /// Austauschpunkt für deterministische Race-Tests; produktiv liest immer
    /// die begrenzte Extraktion aus `AudioFile`.
    var embeddedArtworkLoader: @Sendable (URL) async -> Data? = { url in
        await AudioFile.extractEmbeddedArtwork(from: url)
    }
    public internal(set) var isCoverSuppressed = false
    private var pendingImport: PendingImportBatch?
    @Published public private(set) var isImporting = false
    @Published public private(set) var importCompletedItems = 0
    @Published public private(set) var importTotalItems = 0
    @Published public private(set) var importDetail = ""
    public var canCancelImport: Bool { isImporting && pendingImport != nil }
    @Published public var importErrorMessage: String?
    public private(set) var lastImportFailures: [AudioImportFailure] = []
    private var cliSourceFolderURL: URL?
    private var cliRepresentedFileIDs: [UUID] = []
    private var cliRepresentedChapterTitles: [UUID: String] = [:]
    private nonisolated let preparationCoordinator = ToolProcessCoordinator()
    private nonisolated let mediaInfoCoordinator = ToolProcessCoordinator()
    @Published public var title: String = ""
    @Published public var author: String = ""
    @Published public var genre: String = "Hörbuch"
    @Published public var narrator = ""
    @Published public var series = ""
    @Published public var volumeNumber = ""
    @Published public var language = ""
    /// Fehlt eines der Buchfelder, lohnt ein Blick in die Datei-Tags. An einer
    /// Stelle formuliert: Ein künftiges siebtes Feld gilt sofort in beiden
    /// Importpfaden (GUI-Batch und erwarteter CLI-Import).
    var bookMetadataIncomplete: Bool {
        title.isEmpty || author.isEmpty || narrator.isEmpty
            || series.isEmpty || volumeNumber.isEmpty || language.isEmpty
    }
    @Published public internal(set) var projectSourceIssues: [ProjectSourceIssue] = []
    public internal(set) var loadedProjectURL: URL?
    // Auch entfernte Kapitel können über Undo/Redo wieder aktiv werden.
    var projectSourcesByOrigin: [UUID: ProjectSourceBinding] = [:]
    var projectSourceOrigins: [UUID: [UUID]] = [:]
    var projectSourceIssuesByID: [UUID: ProjectSourceIssue] = [:]
    var projectSourcesBeingWritten: (operation: UUID, chapterIDs: Set<UUID>, byOrigin: [UUID: ProjectSourceBinding])?
    var projectSourceRetentionEdits = 0
    let projectFingerprints = ProjectFingerprintStore()
    var projectOperation = UUID()
    /// Entwertet eine Exportvorschau auch dann, wenn ein neues Projekt dieselben Kapitel enthält.
    public var projectRevision: UUID { projectOperation }
    var chapterHistory = ChapterHistory()
    @Published public internal(set) var canUndoChapters = false
    @Published public internal(set) var canRedoChapters = false
    
    // --- KONVERSION STATUS & LOGGING ---
    @Published public internal(set) var runState = ConversionRunState()
    public internal(set) var isConverting: Bool { get { runState.isConverting } set { runState.isConverting = newValue } }
    public internal(set) var showOverlay: Bool { get { runState.showOverlay } set { runState.showOverlay = newValue } }
    public internal(set) var progress: Double { get { runState.progress } set { runState.progress = newValue } }
    var conversionStatus: String { get { runState.status } set { runState.status = newValue } }
    public internal(set) var conversionPhase: String { get { runState.phase } set { runState.phase = newValue } }
    public internal(set) var completedOutputURLs: [URL] { get { runState.completedOutputs } set { runState.completedOutputs = newValue } }
    /// Ergebnis des letzten Konvertierungslaufs (nil = noch nicht beendet,
    /// true = erfolgreich, false = mit Fehler/abgebrochen). Erlaubt der CLI
    /// einen korrekten Exit-Code statt blind "Erfolg" zu melden.
    public internal(set) var lastConversionSucceeded: Bool? { get { runState.succeeded } set { runState.succeeded = newValue } }

    private nonisolated let conversionCoordinator = ConversionCoordinator()
    private nonisolated let conversionEventQueue = ConversionEventQueue()

    /// Beginnt einen abbrechbaren Import-/Metadatenlauf. Die CLI startet ihn vor
    /// dem asynchron erwarteten Ordnerscan.
    public nonisolated func beginPreparation() {
        importService.clearCachedArtwork()
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
        Task.isCancelled
            || currentPreparationContext()?.isCancelled == true
    }

    /// Führt einen Vorbereitungsschritt als registrierten Swift-Task aus. Der
    /// Signalpfad kann dessen Handle synchron canceln; der Aufrufer wartet
    /// trotzdem auf das saubere Ende, bevor die CLI mit Exit 130 zurückkehrt.
    public nonisolated func runPreparationTask(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) async {
        // Den Context VOR dem Task lesen: Ein gleichzeitiges `beginPreparation`
        // darf den Task nicht beim Nachfolger registrieren, der ihn bei einem
        // späteren Abbruch für seine eigene Arbeit hielte.
        let context = currentPreparationContext()
        let task = Task { @MainActor in
            guard !Task.isCancelled, context?.isCancelled != true else { return }
            await operation()
        }
        await withTaskCancellationHandler {
            await awaitRegisteredTask(task, in: context)
        } onCancel: {
            task.cancel()
            context?.cancel()
        }
    }

    /// Gemeinsamer Registrierungsvertrag beider Task-Einstiege: den Task beim
    /// übergebenen Context anmelden, auf sein Ende warten und ihn danach wieder
    /// abmelden. Ein Context, der den Abbruch bereits gewonnen hat, liefert
    /// keine Registrierung mehr; der Task wird dann sofort gecancelt, der
    /// Aufrufer wartet aber trotzdem auf dessen sauberes Ende — sonst kehrte
    /// die CLI mit Exit 130 zurück, während noch Arbeit läuft.
    private nonisolated func awaitRegisteredTask(
        _ task: Task<Void, Never>,
        in context: PreparationContext?
    ) async {
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

    /// Der Token wird vor der Registrierung und vor dem Taskstart geprüft.
    /// Ein verspäteter Provider darf keinen Kontext des Folgeimports nutzen.
    func runImportTask(
        _ token: ImportToken,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) async {
        guard hasPendingImport(token) else { return }
        let context = currentPreparationContext()
        let task = Task { @MainActor [weak self] in
            guard let self, self.hasPendingImport(token),
                  !Task.isCancelled, context?.isCancelled != true else { return }
            await operation()
        }
        await withTaskCancellationHandler {
            await awaitRegisteredTask(task, in: context)
        } onCancel: {
            task.cancel()
            context?.cancel()
        }
        if hasPendingImport(token), Task.isCancelled || context?.isCancelled == true {
            abandonPendingImport()
        }
    }

    /// Vollständiger CLI-Ordnerimport als abbrechbarer Vorbereitungstask.
    /// Bei explizitem Cover oder `--no-cover` spart `analyzeArtwork == false`
    /// die sonst wirkungslose Analyse eingebetteter und separater Bilder.
    public func prepareFolder(
        _ url: URL,
        analyzeArtwork: Bool = true
    ) async {
        let token = beginImport(expectedItemCount: 1, allowsSelectionUI: false,
                                reusePreparation: true, resumeArtworkSearch: analyzeArtwork)
        await runImportTask(token) {
            let scanned = await self.scanFolder(url, importToken: token, analyzeArtwork: analyzeArtwork)
            self.stageScannedFolder(scanned, importToken: token)
            await self.finishImport(token)
        }
    }

    /// Liest Kapitel mit einem optional laufenden Vorbereitungs-Context. Das
    /// strukturierte Dateipaar verhindert, dass sichtbarer Pfad und Lese-URL
    /// an zwei gleich typisierten Parametern vertauscht werden.
    private nonisolated func extractChapterResult(
        from file: FoundFile,
        importToken: ImportToken? = nil,
        knownFile: AudioFile? = nil
    ) async -> ChapterExtractionResult {
        let context = currentPreparationContext()
        return await AudioFile.extractChaptersControlled(
            from: file,
            knownFile: knownFile,
            shouldCancel: { context?.isCancelled ?? false },
            runProcess: { process in
                if let context {
                    let started = try context.run(process)
                    if started { self.importService.recordChapterRequest() }
                    return started
                }
                try process.run()
                self.importService.recordChapterRequest()
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

    /// Analysiert genau eine gefundene Audiodatei. Ordner- und Einzeldatei-
    /// Import benutzen damit dieselbe Typ-, Symlink- und Dauerlogik.
    nonisolated func loadAudioFiles(
        from file: FoundFile,
        importToken: ImportToken? = nil
    ) async -> AudioLoadResult {
        guard file.kind == .audio else { return .skipped }

        let analysis: ImportedSourceAnalysis
        switch await importService.analyze(file) {
        case .success(let loaded): analysis = loaded
        case .failure(let failure): return .failure(failure)
        case .cancelled: return .cancelled
        }

        let candidates: [AudioFile]
        if file.isChapterContainer {
            switch await extractChapterResult(from: file, importToken: importToken, knownFile: analysis.file) {
            case .files(let files): candidates = files
            case .failed(let reason):
                return .failure(AudioImportFailure(sourceURL: file.source, reason: reason))
            case .cancelled:
                return .cancelled
            }
        } else {
            candidates = [analysis.file]
        }
        guard !preparationCancellationRequested() else { return .cancelled }

        guard analysis.isCurrent() else {
            return .failure(AudioImportFailure(sourceURL: file.source, reason: .sourceChanged))
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

    /// Gemeinsamer Batch-Einstieg für Dateienauswahl und Ordnerscan. Abbruch
    /// gibt ausdrücklich kein scheinbar vollständiges Teilergebnis zurück.
    nonisolated func loadAudioFiles(
        from files: [FoundFile],
        importToken: ImportToken? = nil
    ) async -> [AudioLoadResult] {
        await importService.orderedMap(
            files,
            shouldCancel: { self.preparationCancellationRequested() },
            operation: { file in
                let result = await self.loadAudioFiles(from: file, importToken: importToken)
                if let importToken { await self.reportImportScan(importToken, filename: file.source.lastPathComponent, completed: true) }
                return result
            }
        // Beim Abbruch bleibt die Anzahl der Beiträge gleich, damit der
        // gemeinsame Import abschließen und den Batch verwerfen kann.
        ) ?? files.map { _ in .cancelled }
    }

    /// Startet einen neuen Lauf und macht einen eventuell noch auslaufenden
    /// Vorgänger ungültig. Dessen spätere Completion darf den neuen UI-State
    /// dadurch nicht mehr überschreiben.
    func beginConversionRun() -> ConversionContext {
        let queue = conversionEventQueue
        return conversionCoordinator.begin { runID, message in
            queue.send(.log(message, .warning, runID))
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
    public internal(set) var segmentProgress: [Int: SegmentStatus] { get { runState.segments } set { runState.segments = newValue } }

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
        let prefix = switch type {
        case .warning: "Warnung: "
        case .error: "Fehler: "
        default: ""
        }
        emit("[\(timeStr)] \(prefix)\(message)")
    }

    private func logVerbose(_ message: String) {
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
        phase: ConversionPhase = .encoding,
        runID: UUID
    ) {
        conversionEventQueue.send(.segmentReset(title, phase, runID))
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

    /// Abschluss und übernommene Zielpfade kommen gemeinsam an, weil der
    /// Abschluss den Laufkontext entwertet und spätere Ereignisse verwirft.
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

        case let .segmentReset(title, phase, runID):
            guard isCurrentConversion(runID) else { return }
            conversionPhase = title ?? "AAC-Encoding"
            runState.machinePhase = phase
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
                    success ? "Alle Vorgänge beendet." : "Vorgang mit Fehlern beendet.",
                    type: success ? .highlight : .error
                )
            }
            endConversion(runID)

        case let .cancellationStarted(runID):
            guard isCurrentConversion(runID) else { return }
            conversionStatus = "Abbruch läuft …"
            addLog("Vorgang wird abgebrochen und bereinigt.", type: .info)

        case let .barrier(continuation):
            continuation.resume()
        }
    }
    
    public func logCurrentSettings() {
        addLog("Aktuelle Einstellungen (geladen aus Speicher):", type: .info)
        addLog("   - Mono: \(settings.isMono ? "Ja" : "Nein")", type: .info)
        addLog("   - Bitrate: \(settings.bitrate)", type: .info)
        addLog("   - Abtastrate: \(settings.sampleRate) Hz", type: .info)
        let maximumDuration = settings.maxDurationHours.map { "\($0) Std." } ?? "Unbegrenzt"
        addLog("   - Maximale Dauer: \(maximumDuration)", type: .info)
        addLog("   - Parallelmodus: \(settings.useParallelEncoding ? "Aktiviert" : "Deaktiviert")", type: .info)
    }

    private func initSegmentProgress(index: Int, filename: String, runID: UUID? = nil) {
        if let runID, !isCurrentConversion(runID) { return }
        segmentProgress[index] = SegmentStatus(filename: filename, progress: 0.0)
    }

    private func updateSegmentProgress(index: Int, progress: Double, runID: UUID? = nil) {
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
        showOverlay = false
    }

    public func resetSession() {
        projectOperation = UUID()
        applyChapterList([])
        // Den ganzen Laufzustand ersetzen statt Feld für Feld: Phase und
        // fertige Ausgaben des Vorlaufs blieben sonst stehen.
        self.runState = ConversionRunState()
        self.eventLogs = []
        self.logString = ""
        loadedProjectURL = nil
        projectSourcesByOrigin = [:]
        projectSourceOrigins = [:]
        projectSourceIssuesByID = [:]
        projectSourcesBeingWritten = nil
        projectSourceRetentionEdits = 0
        projectSourceIssues = []
        chapterHistory = ChapterHistory()
        updateHistoryAvailability()
    }

    /// Kennung der zuletzt gestarteten Info-Abfrage. Der neue Werkzeugkontext
    /// beendet zwar den Vorgänger; dessen bereits eingereihte Completion darf
    /// das Ergebnis der zuletzt angefragten Datei trotzdem nicht überschreiben.
    /// Nur auf dem Main Actor lesen/schreiben.
    private var infoRequestToken = UUID()
    /// Austauschpunkt für einen echten, kontrollierbaren Werkzeugprozess im
    /// Regressionstest. Produktiv wird weiterhin das aufgelöste MediaInfo
    /// verwendet.
    var mediaInfoExecutableProvider: @Sendable () -> URL? = {
        ToolLocator.binaryURL(name: "mediainfo")
    }

    /// Nur auf dem Main Actor aufrufen (setzt @Published-State).
    public func fetchRawMediaInfo(for file: AudioFile) {
        let token = UUID()
        self.infoRequestToken = token
        let context = mediaInfoCoordinator.begin()
        self.isFetchingInfo = true
        self.selectedFileInfoText = "Lade Informationen..."
        self.showInfoSheet = true

        let fileURL = file.url
        let executableProvider = mediaInfoExecutableProvider
        Task { [weak self] in
            let text = await Task.detached {
                MediaInfoService.readText(
                    for: fileURL,
                    executableURL: executableProvider(),
                    context: context
                )
            }.value
            self?.updateInfoText(text, token: token)
        }
    }

    /// Schließen und ein neuer Dateiklick entziehen der alten Abfrage zuerst
    /// die Schreibberechtigung und beenden dann deren gesamte Prozessgruppe.
    public func cancelRawMediaInfo() {
        infoRequestToken = UUID()
        _ = mediaInfoCoordinator.cancel()
        isFetchingInfo = false
        showInfoSheet = false
    }

    private func updateInfoText(_ text: String, token: UUID) {
        // Veraltete Antwort verwerfen: Der Nutzer hat inzwischen die Info
        // einer anderen Datei angefragt, deren Ergebnis gewinnen muss.
        guard token == infoRequestToken else { return }
        selectedFileInfoText = text
        isFetchingInfo = false
    }

    public var totalDuration: TimeInterval { audioFiles.reduce(0) { $0 + $1.duration } }

    func clearMetadata() {
        self.title = ""; self.author = ""; self.genre = "Hörbuch"
        narrator = ""; series = ""; volumeNumber = ""; language = ""
        self.coverImage = nil; self.coverPath = nil; self.embeddedCoverData = nil
        self.isCoverSuppressed = false
        self.titleCandidates = []; self.authorCandidates = []
        self.showSelectionUI = false
        invalidateArtworkWork()
        notifyCoverSelectionChange()
    }

    /// Markiert einen neuen GUI-Import und entwertet Antworten des Vorgängers.
    func beginImport(
        expectedItemCount: Int = 1,
        allowsSelectionUI: Bool = true
    ) -> ImportToken {
        beginImport(expectedItemCount: expectedItemCount, allowsSelectionUI: allowsSelectionUI,
                    reusePreparation: false)
    }

    private func beginImport(
        expectedItemCount: Int,
        allowsSelectionUI: Bool,
        reusePreparation: Bool,
        resumeArtworkSearch: Bool = true
    ) -> ImportToken {
        projectOperation = UUID()
        importService.retainCachedArtwork(for: audioFiles.map(\.url))
        // CLI-Signale erreichen den bereits angelegten Vorbereitungskontext.
        // Nur ein neuer GUI-Import oder der Ersatz eines laufenden Batches
        // braucht einen anderen Context für seine eigenen Prozesse und Tasks.
        if !reusePreparation || isImporting || currentPreparationContext() == nil {
            preparationCoordinator.begin()
        }
        importGeneration = UUID()
        let batch = PendingImportBatch(
            expectedItemCount: expectedItemCount,
            shouldResumeArtworkSearch: resumeArtworkSearch && (pendingImport?.shouldResumeArtworkSearch == true || isPreparingArtwork)
        )
        pendingImport = batch
        importCompletedItems = 0
        importTotalItems = batch.remainingItems
        importDetail = "Dateien suchen und analysieren …"
        isImporting = batch.remainingItems > 0
        importErrorMessage = nil
        lastImportFailures = []
        invalidateArtworkWork()
        if batch.remainingItems == 0 { abandonPendingImport() }

        return ImportToken(
            generation: importGeneration,
            coverRevision: coverRevision,
            allowsSelectionUI: allowsSelectionUI
        )
    }

    /// Importiert die explizite Dateiliste in Eingabereihenfolge und wartet auf
    /// den für die CLI benötigten Metadaten- und Coverzustand. Die CLI
    /// verwendet ihre bereits für Prozesssignale registrierte Vorbereitung.
    public func importFiles(
        _ urls: [URL],
        analyzeArtwork: Bool = true,
        usingExistingPreparation: Bool = false
    ) async {
        let token = beginImport(expectedItemCount: urls.count, allowsSelectionUI: false,
                                reusePreparation: usingExistingPreparation)
        let ranks = Dictionary(urls.enumerated().map { ($0.element.standardizedFileURL, $0.offset) },
                               uniquingKeysWith: min)
        await runImportTask(token) {
            await self.processImportURLs(urls, importToken: token, fileOrder: ranks,
                                         analyzeArtwork: analyzeArtwork)
        }
    }

    /// Importiert einen gemeinsamen GUI-Batch aus Dateien und Ordnern.
    public func importURLs(_ urls: [URL]) async {
        let token = beginImport(expectedItemCount: urls.count)
        await runImportTask(token) {
            await self.processImportURLs(urls, importToken: token)
        }
    }

    /// Reserviert den GUI-Batch sofort. Die Dateianalyse startet erst, wenn
    /// die Provider ihre Adressen oder Fehler gemeinsam geliefert haben.
    public func startProviderImport(
        expectedItemCount: Int,
        load: @escaping @MainActor @Sendable () async -> FileProviderImportResult,
        onTimeout: @escaping @MainActor @Sendable () -> Void
    ) {
        let token = beginImport(expectedItemCount: expectedItemCount)
        Task { @MainActor in
            await runImportTask(token) {
                let result = await load()
                guard self.hasPendingImport(token), !Task.isCancelled else { return }
                switch result {
                case .ready(let items):
                    guard items.count == expectedItemCount else {
                        self.cancelImport()
                        return
                    }
                    var urls: [URL] = []
                    for (index, item) in items.enumerated() {
                        switch item {
                        case .url(let url):
                            urls.append(url)
                        case .failure(let details):
                            self.stageProviderLoadFailure(position: index + 1, total: items.count,
                                                          errorDescription: details, importToken: token)
                        }
                    }
                    await self.finishImport(token, completed: items.count - urls.count,
                                            countingProgress: true)
                    await self.processImportURLs(urls, importToken: token)
                case .timedOut:
                    self.cancelImport()
                    onTimeout()
                case .cancelled:
                    self.cancelImport()
                }
            }
        }
    }

    private func processImportURLs(
        _ urls: [URL],
        importToken token: ImportToken,
        fileOrder: [URL: Int]? = nil,
        analyzeArtwork: Bool = true
    ) async {
        var files: [FoundFile] = []
        let inputs = await SourceDiscovery.classify(urls, allowFolders: fileOrder == nil)
        for input in inputs {
            guard hasPendingImport(token), !Task.isCancelled else { return }
            switch input {
            case .folder(let url):
                let scanned = await scanFolder(url, importToken: token)
                stageScannedFolder(scanned, importToken: token)
                await finishImport(token)
            case .file(let found):
                files.append(found)
            case .unreadable(let url):
                stageAudioLoadResult(.failure(AudioImportFailure(sourceURL: url, reason: .analysisFailed)),
                                     importToken: token)
                await finishImport(token)
            }
        }
        guard hasPendingImport(token), !files.isEmpty else { return }
        let results = await loadAudioFiles(from: files, importToken: token)
        for result in results { stageAudioLoadResult(result, importToken: token) }
        if fileOrder != nil, hasPendingImport(token) {
            // Die CLI liest das Cover direkt nach dem Import; ihr Ergebnis
            // darf von keiner nachträglichen Hintergrundsuche abhängen.
            pendingImport?.requiresArtworkSearch = false
            if analyzeArtwork, let batch = pendingImport, batch.failures.isEmpty, !batch.wasCancelled {
                switch await firstEmbeddedArtwork(in: batch.audioFiles) {
                case .found(let artwork):
                    if hasPendingImport(token) { pendingImport?.embeddedArtwork = artwork }
                case .none:
                    break
                case .cancelled:
                    if hasPendingImport(token) { pendingImport?.wasCancelled = true }
                }
            }
        }
        await finishImport(token, completed: results.count, countingProgress: false, fileOrder: fileOrder)
    }

    func finishImport(_ token: ImportToken, countingProgress: Bool = true, analyzeArtwork: Bool = true) async {
        await finishImport(token, completed: 1, countingProgress: countingProgress, analyzeArtwork: analyzeArtwork)
    }

    private func finishImport(
        _ token: ImportToken,
        completed: Int,
        countingProgress: Bool,
        fileOrder: [URL: Int]? = nil,
        analyzeArtwork: Bool = true
    ) async {
        guard hasPendingImport(token), completed > 0,
              let remaining = pendingImport?.remainingItems, completed <= remaining else { return }
        pendingImport?.remainingItems -= completed
        if countingProgress { importCompletedItems += completed }
        guard remaining == completed, let batch = pendingImport else { return }
        if batch.wasCancelled || preparationCancellationRequested() {
            abandonPendingImport()
            return
        }
        if !batch.failures.isEmpty {
            batch.warnings.forEach { addLog($0) }
            batch.failures.forEach { addLog($0.logMessage, type: .error) }
            lastImportFailures = batch.failures
            importErrorMessage = Self.importFailureMessage(batch.failures)
            abandonPendingImport()
            return
        }

        let artwork = await prepareImportArtwork(
            embedded: batch.embeddedArtwork, imageURLs: batch.imageURLs,
            coverRevision: token.coverRevision
        )
        guard hasPendingImport(token) else { return }
        guard !preparationCancellationRequested() else {
            abandonPendingImport()
            return
        }
        importDetail = "Metadaten übernehmen …"
        pendingImport = nil
        let first = applyScannedFolderContents(
            audioFiles: batch.audioFiles,
            artwork: artwork,
            expectedCoverRevision: token.coverRevision,
            warnings: batch.warnings,
            importToken: token,
            sourceFolderForCLI: batch.sourceFolder,
            skipCoverExtraction: !analyzeArtwork || !batch.requiresArtworkSearch,
            fileOrder: fileOrder
        ) ?? audioFiles.first
        if batch.shouldResumeArtworkSearch && !isPreparingArtwork { startArtworkSearch() }

        if bookMetadataIncomplete, let first {
            await importGlobalMetadata(from: first, importToken: token)
            await finishMetadataImport(token: token, sourceFileID: first.id)
        } else {
            isImporting = false
        }
        // Ein inzwischen gestarteter Import besitzt seinen eigenen Analyse-Cache.
        // Nur der aktuelle Abschluss darf ihn auf den sichtbaren Bestand kürzen.
        guard isCurrentImport(token) else { return }
        importService.retainCachedArtwork(for: audioFiles.map(\.url))
    }

    private func finishMetadataImport(token: ImportToken, sourceFileID: UUID) async {
        guard isCurrentImport(token) else { return }
        guard !preparationCancellationRequested() else {
            isImporting = false
            return
        }
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

    /// Verwirft ausschließlich den noch nicht übernommenen Zusatzimport. Der
    /// Generationstausch sperrt auch Provider, die nach dem Abbruch antworten.
    public func cancelImport() {
        guard canCancelImport else { return }
        _ = preparationCoordinator.cancel()
        importGeneration = UUID()
        importDetail = "Import abgebrochen"
        abandonPendingImport()
    }

    private func reportImportScan(_ token: ImportToken, total: Int? = nil, filename: String? = nil, completed: Bool = false) {
        guard hasPendingImport(token) else { return }
        if let total { importTotalItems += max(0, total) }
        if let filename { importDetail = filename }
        if completed { importCompletedItems += 1 }
    }

    func applyChapterList(_ files: [AudioFile]) {
        audioFiles = files
        compactProjectSourceHistoryIfNeeded()
        updateActiveProjectSourceIssues()
        if files.isEmpty {
            importService.clearCachedArtwork()
            invalidateImportWork()
            clearMetadata()
        }
    }

    private func invalidateImportWork() {
        _ = preparationCoordinator.cancel()
        importGeneration = UUID()
        pendingImport = nil
        isImporting = false
        cliSourceFolderURL = nil
        cliRepresentedFileIDs = []
        cliRepresentedChapterTitles = [:]
        invalidateArtworkWork()
    }

    private func abandonPendingImport() {
        let shouldResumeArtworkSearch = pendingImport?.shouldResumeArtworkSearch == true
        pendingImport = nil
        isImporting = false
        if shouldResumeArtworkSearch { startArtworkSearch() }
    }

    private func hasPendingImport(_ token: ImportToken) -> Bool {
        pendingImport != nil && isCurrentImport(token)
    }

    private static func importFailureMessage(_ failures: [AudioImportFailure]) -> String {
        let details = failures.map {
            "• \($0.sourceDescription): \($0.message)"
        }.joined(separator: "\n")
        return "Der Import wurde vollständig verworfen, damit kein Hörbuch mit fehlenden Kapiteln entsteht.\n\n\(details)"
    }

    private func invalidateArtworkWork() {
        artworkTask?.cancel()
        artworkTask = nil
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
        let currentIDs = audioFiles.map(\.id)
        let chapterTitlesStillMatch = audioFiles.allSatisfy {
            cliRepresentedChapterTitles[$0.id] == $0.chapterTitle
        }
        guard !currentIDs.isEmpty,
              currentIDs == cliRepresentedFileIDs,
              chapterTitlesStillMatch else { return nil }
        return cliSourceFolderURL
    }
    
    private func commitAudioFiles(
        _ newFiles: [AudioFile],
        sourceFolderForCLI: URL?,
        fileOrder: [URL: Int]? = nil
    ) -> AudioFile? {
        guard !newFiles.isEmpty else { return nil }
        let canRepresentFolder = audioFiles.isEmpty && sourceFolderForCLI != nil
        let sourceCount = Set(newFiles.map { $0.sourceURL.standardizedFileURL.path }).count
        let sourceLabel = sourceCount == 1 ? "Audiodatei" : "Audiodateien"
        if sourceCount == newFiles.count {
            addLog("Importiere \(sourceCount) \(sourceLabel)...")
        } else {
            addLog("Importiere \(sourceCount) \(sourceLabel) mit \(newFiles.count) Kapiteln...")
        }
        let deduplicated = SourceDiscovery.deduplicateAudioFiles(audioFiles + newFiles)
        let existingIDs = Set(audioFiles.map(\.id))
        let orderedFiles = deduplicated.files.filter { existingIDs.contains($0.id) }
            + deduplicated.files.filter { !existingIDs.contains($0.id) }.sorted(by: SourceDiscovery.audioFileComesBefore)
        if let fileOrder {
            editChapters(orderedFiles.sorted {
                let left = fileOrder[$0.sourceURL.standardizedFileURL] ?? Int.max
                let right = fileOrder[$1.sourceURL.standardizedFileURL] ?? Int.max
                return left == right ? $0.startTime < $1.startTime : left < right
            })
        } else {
            editChapters(orderedFiles)
        }
        for duplicate in deduplicated.discardedSources {
            // Derselbe Pfad in beiden Feldern heißt: Ein Drop hat diese Datei
            // mehrfach geliefert (z.B. Ordner plus eine Datei daraus). Die
            // Zwei-Namen-Meldung nennte hier zweimal denselben Namen.
            if duplicate.discarded == duplicate.kept {
                addLog(
                    "\(duplicate.kept.lastPathComponent) wurde mehrfach übergeben; "
                    + "importiert wird nur ein Exemplar."
                )
            } else {
                addLog(
                    "\(duplicate.discarded.lastPathComponent) und \(duplicate.kept.lastPathComponent) "
                    + "lesen dieselbe Audiodatei; importiert wird nur \(duplicate.kept.lastPathComponent)."
                )
            }
        }
        if canRepresentFolder, let sourceFolderForCLI {
            cliSourceFolderURL = sourceFolderForCLI
            cliRepresentedFileIDs = audioFiles.map(\.id)
            cliRepresentedChapterTitles = Dictionary(uniqueKeysWithValues: audioFiles.map { ($0.id, $0.chapterTitle) })
        } else {
            cliSourceFolderURL = nil
            cliRepresentedFileIDs = []
            cliRepresentedChapterTitles = [:]
        }
        // Die explizite CLI-Reihenfolge bestimmt die Kapitel. Metadaten werden
        // weiter aus der ersten Datei nach natürlicher Sortierung ermittelt.
        return orderedFiles.first
    }

    /// Startet genau eine Suche über den aktuellen, bereits übernommenen
    /// Dateistand. Fehlerhafte oder abgebrochene Zusatz-Drops rufen denselben
    /// Pfad erneut auf, nachdem sie die frühere Suche entwertet hatten.
    func startArtworkSearch(importToken: ImportToken? = nil) {
        guard !audioFiles.isEmpty,
              !isCoverSuppressed,
              coverImage == nil,
              coverPath == nil else { return }
        artworkTask?.cancel()
        let request = UUID()
        artworkRequest = request
        let expectedCoverRevision = coverRevision
        let filesToSearch = audioFiles
        let artworkLoader = embeddedArtworkLoader
        isPreparingArtwork = true
        artworkTask = Task { [weak self] in
            var foundArtwork: PreparedEmbeddedArtwork?
            for file in Self.uniqueArtworkCandidates(filesToSearch) {
                guard !Task.isCancelled, self?.artworkRequest == request else { return }
                let artworkData = await artworkLoader(file.url)
                guard !Task.isCancelled, self?.artworkRequest == request else { return }
                if let artworkData {
                    // Manche Container deklarieren beliebige Binärdaten als
                    // Artwork. Nur tatsächlich dekodierbare Bilder dürfen in
                    // den späteren ffmpeg-Auftrag gelangen.
                    let candidate = await Task.detached { PreparedEmbeddedArtwork(artworkData) }.value
                    guard let candidate else { continue }
                    guard !Task.isCancelled, let self, self.artworkRequest == request else { return }
                    guard self.coverRevision == expectedCoverRevision,
                          !self.isCoverSuppressed,
                          importToken.map(self.isCurrentImport) ?? true,
                          self.coverImage == nil,
                          self.coverPath == nil else { return }
                    // Das Cover gehört der Datei. Ein weiteres Kapitel aus
                    // demselben Container darf es weiterhin übernehmen.
                    let source = file.url.standardizedFileURL
                    guard self.audioFiles.contains(where: { $0.url.standardizedFileURL == source }) else {
                        continue
                    }
                    foundArtwork = candidate
                    break
                }
            }
            guard let self, self.artworkRequest == request else { return }
            self.artworkTask = nil
            // Der aktuelle Request ist in jedem Fall beendet. Weitere Guards
            // entscheiden nur noch, ob sein Ergebnis anwendbar ist.
            self.isPreparingArtwork = false
            guard self.coverRevision == expectedCoverRevision,
                  !self.isCoverSuppressed,
                  importToken.map(self.isCurrentImport) ?? true else { return }
            // Ein zwischenzeitlich manuell gesetztes Cover gewinnt.
            guard self.coverImage == nil, self.coverPath == nil,
                  let foundArtwork else { return }
            self.coverImage = foundArtwork.image
            self.coverPath = nil
            self.embeddedCoverData = foundArtwork.data
        }
    }

    private func importGlobalMetadata(
        from file: AudioFile,
        importToken: ImportToken?
    ) async {
        let preparation = currentPreparationContext()
        let fileURL = file.url
        // Der mediainfo-Prozess liefert ausschließlich Titel-/Autor-Kandidaten.
        // Sind beide schon gesetzt (etwa nur Sprecher/Reihe/Band/Sprache
        // fehlen), kann er nichts mehr beitragen und entfällt — sonst öffnete
        // ein fehlgeschlagener Lauf eine leere Auswahl in der GUI.
        let needsTitleAuthorCandidates = title.isEmpty || author.isEmpty
        let importService = self.importService
        let (candidates, metadata) = await Task.detached {
            let candidates = needsTitleAuthorCandidates
                ? MediaInfoService.readTitleAndAuthor(for: fileURL, context: preparation) : nil
            return (candidates, importService.metadata(for: fileURL))
        }.value

        guard !Task.isCancelled,
              importToken.map(isCurrentImport) ?? true,
              importToken == nil || audioFiles.contains(where: { $0.id == file.id }),
              preparation?.isCancelled != true else {
            return
        }
        if let metadata {
            if narrator.isEmpty { narrator = metadata["narrator"] ?? "" }
            if series.isEmpty { series = metadata["series"] ?? "" }
            if volumeNumber.isEmpty { volumeNumber = metadata["volume_number"] ?? "" }
            if language.isEmpty { language = metadata["language"] ?? "" }
        }
        // Kandidaten gehören immer genau zum aktuellen Import, auch wenn Titel
        // und Autor schon feststehen und MediaInfo deshalb nicht laufen musste.
        guard needsTitleAuthorCandidates else {
            titleCandidates = []
            authorCandidates = []
            return
        }
        guard let candidates else {
            // Kandidaten gehören immer genau zum aktuellen Import. Andernfalls
            // könnte die Auswahl nach einem MediaInfo-Fehler Werte des vorherigen
            // Buchs anbieten.
            titleCandidates = []
            authorCandidates = []
            showSelectionUI = importToken?.allowsSelectionUI ?? false
            return
        }
        titleCandidates = candidates.titles
        authorCandidates = candidates.authors
        // Der Token bezeichnet einen Batch, nicht das Frontend. Die CLI nutzt
        // für `--file` ebenfalls einen Token und sperrt die Auswahl ausdrücklich.
        let resolution = MediaInfoService.resolveMetadata(
            currentTitle: title,
            currentAuthor: author,
            titleCandidates: candidates.titles,
            authorCandidates: candidates.authors,
            allowsSelectionUI: importToken?.allowsSelectionUI ?? false
        )
        title = resolution.title
        author = resolution.author
        showSelectionUI = resolution.shouldShowSelection
    }

    /// Schwerer Teil des Ordner-Imports: rekursiv scannen, m4b-Kapitel via ffmpeg
    /// extrahieren, Dauern/eingebettetes Artwork lesen. Rührt **keinen**
    /// `@Published`-State an. Die AVFoundation-Aufrufe suspendieren asynchron;
    /// der Dateisystem- und ffmpeg-Anteil läuft außerhalb des Main Actors.
    /// `analyzeArtwork == false` überspringt sowohl Ordnerbilder als auch
    /// eingebettete Bilder, wenn der Aufrufer sie danach ohnehin ersetzt.
    nonisolated func scanFolder(
        _ url: URL,
        importToken: ImportToken? = nil,
        analyzeArtwork: Bool = true
    ) async -> ScannedFolder {
        var foundAudio: [AudioFile] = []
        var foundImages: [URL] = []
        var warnings: [String] = []
        var analysisFailures: [AudioImportFailure] = []

        func cancelledResult() -> ScannedFolder {
            // Nie ein bis zum Abbruch aufgebautes Teilergebnis herausgeben: Ein
            // direkter Aufrufer könnte es sonst als vollständigen Scan anwenden.
            ScannedFolder(
                folderURL: url,
                audioFiles: [],
                imageURLs: [],
                embeddedArtwork: nil,
                warnings: warnings,
                wasCancelled: true
            )
        }

        let discovery = SourceDiscovery.discoverFileURLs(
            in: url,
            cancellationRequested: { preparationCancellationRequested() }
        )
        if preparationCancellationRequested() { return cancelledResult() }
        if let failure = discovery.failureDescription {
            return ScannedFolder(
                folderURL: url,
                audioFiles: [],
                imageURLs: [],
                embeddedArtwork: nil,
                warnings: ["Ordner konnte nicht vollständig gelesen werden: \(failure)"],
                failures: [AudioImportFailure(sourceURL: url, reason: .analysisFailed)]
            )
        }
        let discovered = discovery.files
        let supported = discovered.filter { $0.kind != .unsupported }
        let deduplicated = SourceDiscovery.deduplicateFoundFiles(supported)
        var loggedTargets = Set<String>()
        for discarded in deduplicated.discarded {
            let target = discarded.resolved.standardizedFileURL.path
            guard loggedTargets.insert(target).inserted else { continue }
            let kept = deduplicated.files.first {
                $0.resolved.standardizedFileURL.path == target
            }
            warnings.append(
                "Mehrere Ordner-Einträge zeigen auf \(discarded.resolved.lastPathComponent); "
                + "importiert wird nur \(kept?.source.lastPathComponent ?? discarded.source.lastPathComponent)."
            )
        }

        if let importToken {
            await reportImportScan(importToken, total: deduplicated.files.filter { $0.kind == .audio }.count)
        }
        let audioSources = deduplicated.files.filter { $0.kind == .audio }
        if analyzeArtwork {
            foundImages = deduplicated.files.filter { $0.kind == .image }.map(\.readURL)
        }
        guard let results = await importService.orderedMap(
            audioSources,
            shouldCancel: { self.preparationCancellationRequested() },
            operation: { found in
                if let importToken {
                    await self.reportImportScan(importToken, filename: found.source.lastPathComponent)
                }
                let loaded = await self.loadAudioFiles(from: found, importToken: importToken)
                if let importToken { await self.reportImportScan(importToken, completed: true) }
                return loaded
            }
        ) else { return cancelledResult() }
        for loaded in results {
            if loaded.wasCancelled { return cancelledResult() }
            foundAudio.append(contentsOf: loaded.files)
            warnings.append(contentsOf: loaded.warnings)
            // Jeden Dateifehler in Eingangsreihenfolge behalten; ein kaputter
            // früher Eingang darf die Analyse der späteren Quellen nicht verhindern.
            analysisFailures.append(contentsOf: loaded.failures)
        }
        if preparationCancellationRequested() { return cancelledResult() }
        var embedded: Data?
        if analyzeArtwork {
            switch await firstEmbeddedArtwork(in: foundAudio) {
            case .found(let artworkData): embedded = artworkData
            case .none: break
            case .cancelled: return cancelledResult()
            }
        }
        if preparationCancellationRequested() { return cancelledResult() }
        return ScannedFolder(
            folderURL: url,
            audioFiles: foundAudio,
            imageURLs: foundImages,
            embeddedArtwork: embedded,
            warnings: warnings,
            failures: analysisFailures
        )
    }

    public nonisolated static func areReadableAudioFiles(_ urls: [URL]) async -> Bool {
        let inputs = await SourceDiscovery.classify(urls, allowFolders: false)
        return !Task.isCancelled && inputs.allSatisfy { input in
            guard case .file(let file) = input else { return false }
            return file.kind == .audio
        }
    }

    /// Ein m4b liefert mehrere Kapitel mit derselben physischen URL. Seine
    /// eingebetteten Metadaten müssen trotzdem nur einmal gelesen werden.
    nonisolated static func uniqueArtworkCandidates(_ files: [AudioFile]) -> [AudioFile] {
        var seen = Set<String>()
        return files.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
    }

    func stageAudioLoadResult(_ result: AudioLoadResult, importToken: ImportToken) {
        guard hasPendingImport(importToken) else { return }
        pendingImport?.stage(result)
    }

    /// Ergebnis der Cover-Suche. Der Abbruch ist ausdrücklich ein eigener Fall:
    /// Der Ordnerscan verwirft daraufhin den ganzen Batch, während „kein Cover
    /// gefunden" ein gültiges Ergebnis ist.
    private enum EmbeddedArtworkSearch: Sendable {
        case found(Data)
        case none
        case cancelled
    }

    /// Erstes dekodierbares eingebettetes Cover der Kandidaten. Manche Container
    /// deklarieren beliebige Binärdaten als Artwork, deshalb muss ImageIO eine
    /// begrenzte Vorschau daraus erzeugen können.
    private nonisolated func firstEmbeddedArtwork(in files: [AudioFile]) async -> EmbeddedArtworkSearch {
        for audioFile in Self.uniqueArtworkCandidates(files) {
            if preparationCancellationRequested() { return .cancelled }
            if let artworkData = await importService.artwork(at: audioFile.url) {
                if preparationCancellationRequested() { return .cancelled }
                if PreparedEmbeddedArtwork(artworkData) != nil { return .found(artworkData) }
            }
        }
        return preparationCancellationRequested() ? .cancelled : .none
    }

    func stageProviderLoadFailure(
        position: Int,
        total: Int,
        errorDescription: String?,
        importToken: ImportToken
    ) {
        let failure = AudioImportFailure(dropItemAt: position, total: total, details: errorDescription)
        stageAudioLoadResult(.failure(failure), importToken: importToken)
    }

    func stageScannedFolder(_ scanned: ScannedFolder, importToken: ImportToken) {
        guard hasPendingImport(importToken) else { return }
        pendingImport?.stage(scanned)
    }

    private func prepareImportArtwork(
        embedded: Data?, imageURLs: [URL], coverRevision revision: UInt
    ) async -> PreparedImportArtwork {
        guard revision == coverRevision, !isCoverSuppressed else { return PreparedImportArtwork() }
        let mayUseEmbedded = coverImage == nil && coverPath == nil
        return await PreparedImportArtwork.load(embedded: mayUseEmbedded ? embedded : nil, images: imageURLs)
    }

    private func applyScannedFolderContents(
        audioFiles: [AudioFile],
        artwork: PreparedImportArtwork,
        expectedCoverRevision: UInt,
        warnings: [String],
        importToken: ImportToken?,
        sourceFolderForCLI: URL?,
        skipCoverExtraction: Bool,
        fileOrder: [URL: Int]? = nil
    ) -> AudioFile? {
        for warning in warnings { addLog(warning) }
        if coverRevision == expectedCoverRevision, !isCoverSuppressed,
           coverImage == nil, coverPath == nil, let embedded = artwork.embedded {
            coverImage = embedded.image
            coverPath = nil
            embeddedCoverData = embedded.data
            isCoverSuppressed = false
        }
        let first = commitAudioFiles(audioFiles, sourceFolderForCLI: sourceFolderForCLI,
                                     fileOrder: fileOrder)
        if first != nil && !skipCoverExtraction { startArtworkSearch(importToken: importToken) }
        if importToken.map(isCurrentImport) ?? true,
           coverRevision == expectedCoverRevision,
           !isCoverSuppressed,
           let cover = artwork.loose {
            applyCover(cover)
        }
        return first
    }

    public struct PreparedCover: Sendable {
        fileprivate let url: URL
        fileprivate let data: Data
        fileprivate let thumbnail: CGImage

        /// Das Original bleibt mit der Auswahl verbunden, auch wenn sich die
        /// Datei danach ändert. Ein Worker kann Lesen und Dekodieren übernehmen.
        public init?(url: URL) {
            guard let data = CoverArtwork.readFile(at: url, isCancelled: { Task.isCancelled }),
                  let thumbnail = CoverArtwork.thumbnail(from: data, maximumDimension: 2_000),
                  !Task.isCancelled else { return nil }
            self.url = url
            self.data = data
            self.thumbnail = thumbnail
        }
    }

    @discardableResult
    public func selectCover(url: URL) -> Bool {
        guard let cover = PreparedCover(url: url) else { return false }
        selectCover(cover)
        return true
    }

    public func selectCover(_ cover: PreparedCover) {
        applyCover(cover)
        notifyCoverSelectionChange()
    }

    private func applyCover(_ cover: PreparedCover) {
        coverRevision &+= 1
        invalidateArtworkWork()
        coverImage = NSImage(cgImage: cover.thumbnail,
                             size: NSSize(width: cover.thumbnail.width, height: cover.thumbnail.height))
        coverPath = cover.url.path
        embeddedCoverData = cover.data
        isCoverSuppressed = false
    }

    public func removeCover() {
        coverRevision &+= 1
        invalidateArtworkWork()
        coverImage = nil
        coverPath = nil
        embeddedCoverData = nil
        isCoverSuppressed = true
        notifyCoverSelectionChange()
    }

    func notifyCoverSelectionChange() {
        coverSelectionDidChange.send()
    }
}
