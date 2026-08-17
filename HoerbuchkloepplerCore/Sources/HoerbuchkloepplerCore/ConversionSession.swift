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

/// Besitzt nur die externen Prozesse des Imports (Kapitel- und Metadatenanalyse).
/// Damit kann die CLI schon vor dem eigentlichen Konvertierungs-Context auf
/// Ctrl-C reagieren, ohne Prozesse eines anderen Fensters anzufassen.
private final class PreparationContext: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]
    private var taskCancellations: [UUID: @Sendable () -> Void] = [:]
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func register(_ process: Process) -> Bool {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return false
        }
        processes[ObjectIdentifier(process)] = process
        lock.unlock()
        return true
    }

    func unregister(_ process: Process) {
        lock.lock()
        processes.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
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
        activeProcesses.forEach { if $0.isRunning { $0.terminate() } }
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

    func begin() -> ConversionContext {
        let next = ConversionContext()
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

@MainActor
public final class ConversionSession: ObservableObject, Identifiable {
    public let id = UUID()
    @Published public var settings: AudioSettings
    public init(settings: AudioSettings = SettingsManager.shared.loadSettings()) {
        self.settings = settings.normalized()
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
    nonisolated func runPreparationTask(
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

    /// Vollständiger CLI-Ordnerimport als abbrechbarer Vorbereitungstask.
    public nonisolated func prepareFolder(_ url: URL) async {
        await runPreparationTask { @MainActor [weak self] in
            await self?.addFolder(url)
        }
    }

    /// Liest Kapitel mit einem optional laufenden Vorbereitungs-Context. Die
    /// öffentliche Methode hält diese Prozessverwaltung aus `ContentView`.
    public nonisolated func extractChapters(from url: URL,
                                            sourceURL: URL? = nil) async -> [AudioFile]? {
        let context = currentPreparationContext()
        return await AudioFile.extractChaptersControlled(
            from: url,
            sourceURL: sourceURL,
            shouldCancel: { context?.isCancelled ?? false },
            registerProcess: { context?.register($0) ?? true },
            unregisterProcess: { context?.unregister($0) },
            log: { [weak self] message in
                Task { @MainActor in self?.addLog(message) }
            }
        )
    }

    /// Startet einen neuen Lauf und macht einen eventuell noch auslaufenden
    /// Vorgänger ungültig. Dessen spätere Completion darf den neuen UI-State
    /// dadurch nicht mehr überschreiben.
    nonisolated func beginConversionRun() -> ConversionContext {
        conversionCoordinator.begin()
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

    nonisolated func endConversion(_ id: UUID) {
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
        logString = eventLogs.map { $0.message }.joined(separator: "\n")
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
    nonisolated func enqueueLog(_ message: String, type: LogType = .info) {
        Task { @MainActor [weak self] in self?.addLog(message, type: type) }
    }

    nonisolated func enqueueVerboseLog(_ message: String) {
        Task { @MainActor [weak self] in self?.logVerbose(message) }
    }

    nonisolated func enqueueSegmentReset(
        title: String?,
        runID: UUID
    ) {
        Task { @MainActor [weak self] in
            guard let self, isCurrentConversion(runID) else { return }
            segmentProgress = [:]
            if let title {
                initSegmentProgress(index: 0, filename: title, runID: runID)
            }
        }
    }

    nonisolated func enqueueSegmentInitialization(
        index: Int,
        filename: String,
        runID: UUID
    ) {
        Task { @MainActor [weak self] in
            self?.initSegmentProgress(index: index, filename: filename, runID: runID)
        }
    }

    nonisolated func enqueueProgress(
        _ value: Double,
        segmentIndex: Int? = nil,
        segmentProgress: Double? = nil,
        runID: UUID
    ) {
        Task { @MainActor [weak self] in
            guard let self, isCurrentConversion(runID) else { return }
            progress = max(progress, value)
            if let segmentIndex, let segmentProgress {
                updateSegmentProgress(
                    index: segmentIndex,
                    progress: segmentProgress,
                    runID: runID
                )
            }
        }
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
        Task { @MainActor [weak self] in
            guard let self, isCurrentConversion(runID) else { return }
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
        }
    }

    nonisolated func enqueueCancellationStarted(runID: UUID) {
        Task { @MainActor [weak self] in
            guard let self, isCurrentConversion(runID) else { return }
            conversionStatus = "Abbruch läuft …"
            addLog("🛑 Vorgang wird abgebrochen und bereinigt.", type: .info)
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
        let process = Process()
        process.executableURL = miURL
        process.arguments = [fileURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard !data.isEmpty else {
                return "MediaInfo hat keine Informationen geliefert."
            }
            return decodeMediaInfoText(from: data) ?? "Dekodierung fehlgeschlagen."
        } catch {
            return "Fehler: \(error.localizedDescription)"
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
        importGeneration = UUID()
        pendingImportOperations = max(0, expectedItemCount)
        isImporting = pendingImportOperations > 0
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
        importGeneration = UUID()
        pendingImportOperations = 0
        isImporting = false
        cliSourceFolderURL = nil
        cliRepresentedFileIDs = []
        cliRepresentedChapterTitles = [:]
        invalidateArtworkWork()
    }

    private func invalidateArtworkWork() {
        artworkRequest = UUID()
        isPreparingArtwork = false
    }

    private func isCurrentImport(_ token: ImportToken) -> Bool {
        token.generation == importGeneration
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
        addLog("📥 Importiere \(newFiles.count) Datei(en)...")
        self.audioFiles.append(contentsOf: newFiles)
        self.audioFiles.sort { (a, b) -> Bool in
            // Natürliche Sortierung wie im Finder: "Teil 2" kommt vor "Teil 10".
            // Reines String-< würde unnummerierte Ziffernfolgen falsch ordnen
            // (1, 10, 11, ..., 2) und damit die Kapitelreihenfolge zerstören.
            if a.name != b.name { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return a.startTime < b.startTime
        }
        if canRepresentFolder, let sourceFolderForCLI, !newFiles.isEmpty {
            cliSourceFolderURL = sourceFolderForCLI
            cliRepresentedFileIDs = Set(audioFiles.map(\.id))
            cliRepresentedChapterTitles = Dictionary(uniqueKeysWithValues: audioFiles.map { ($0.id, $0.chapterTitle) })
        } else if !newFiles.isEmpty {
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
                var foundArtwork: (image: NSImage?, data: Data)?
                for file in filesToSearch {
                    if let artworkData = await AudioFile.extractEmbeddedArtwork(from: file.url) {
                        foundArtwork = (NSImage(data: artworkData), artworkData)
                        break
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
                let process = Process()
                process.executableURL = miURL
                process.arguments = ["--Output=JSON", fileURL.path]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                if preparation?.register(process) ?? true {
                    defer { preparation?.unregister(process) }
                    do {
                        guard preparation?.isCancelled != true else { throw CancellationError() }
                        try process.run()
                        // Dasselbe Start-Race wie bei Encoding-Prozessen: Ein
                        // Cancel unmittelbar vor `run()` sah den Process noch
                        // nicht laufen. Nach dem Start sofort erneut prüfen.
                        if preparation?.isCancelled == true { process.terminate() }
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        guard process.terminationStatus == 0,
                              preparation?.isCancelled != true,
                              let general = Self.decodeMediaInfoGeneralTrack(from: data) else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        result = Self.metadataCandidates(from: general)
                    } catch {
                        // Ein fehlender/kaputter Tag-Lauf fällt unten auf die
                        // manuelle Auswahl zurück. Abbruch zeigt keine neue UI.
                    }
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
            showSelectionUI = true
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
        public var sourceURL: URL
        public var audioFiles: [AudioFile]
        public var imageURLs: [URL]
        public var embeddedArtwork: Data?
    }

    /// Schwerer Teil des Ordner-Imports: rekursiv scannen, m4b-Kapitel via ffmpeg
    /// extrahieren, Dauern/eingebettetes Artwork lesen. Rührt **keinen**
    /// `@Published`-State an. Die AVFoundation-Aufrufe suspendieren asynchron;
    /// der Dateisystem- und ffmpeg-Anteil läuft außerhalb des Main Actors.
    public nonisolated func scanFolder(_ url: URL) async -> ScannedFolder {
        var foundAudio: [AudioFile] = []; var foundImages: [URL] = []
        for found in Self.recursiveFileURLs(
            in: url,
            cancellationRequested: { preparationCancellationRequested() }
        ) {
            if preparationCancellationRequested() { break }
            let fileURL = found.resolved
            // Der Dateityp folgt dem SICHTBAREN Namen: unter diesem Namen hat
            // der Nutzer die Datei in den Ordner gelegt.
            let ext = found.source.pathExtension.lowercased()
            if ["mp3", "m4a", "wav", "flac", "m4b", "mp4"].contains(ext) {
                if ["m4b", "mp4"].contains(ext),
                   let chapters = await extractChapters(from: fileURL,
                                                        sourceURL: found.source) {
                    if preparationCancellationRequested() { break }
                    foundAudio.append(contentsOf: chapters)
                } else {
                    let audioFile = await AudioFile(url: fileURL,
                                                    sourceURL: found.source)
                    if preparationCancellationRequested() { break }
                    foundAudio.append(audioFile)
                }
            } else if ["jpg", "jpeg", "png"].contains(ext) { foundImages.append(fileURL) }
        }
        var embedded: Data? = nil
        for audioFile in foundAudio {
            if preparationCancellationRequested() { break }
            if let artworkData = await AudioFile.extractEmbeddedArtwork(from: audioFile.url) {
                if preparationCancellationRequested() { break }
                embedded = artworkData
                break
            }
        }
        return ScannedFolder(sourceURL: url, audioFiles: foundAudio, imageURLs: foundImages, embeddedArtwork: embedded)
    }

    /// `FileManager.DirectoryEnumerator` ist absichtlich nicht über einen
    /// asynchronen Aufruf hinweg haltbar. Die Dateiliste wird deshalb synchron
    /// aufgebaut, prüft den laufbezogenen Abbruch aber vor und nach jedem
    /// `nextObject()`, damit auch ein großer Ordnerscan sofort enden kann.
    /// Eine gefundene Datei mit ihren beiden Pfaden.
    ///
    /// `source` ist der Pfad, unter dem der Nutzer die Datei im Ordner sieht —
    /// bei einem Symlink also der Linkname. `resolved` ist die reguläre Datei,
    /// aus der wirklich gelesen wird. Für eine gewöhnliche Datei sind beide
    /// gleich. Getrennt geführt, weil Sortierung und Kapiteltitel dem sichtbaren
    /// Namen folgen müssen, AVFoundation und ffmpeg aber dem Ziel
    /// (Review-Fund 2026-08-17).
    nonisolated struct FoundFile: Sendable {
        let source: URL
        let resolved: URL
    }

    nonisolated static func recursiveFileURLs(
        in url: URL,
        cancellationRequested: () -> Bool = { false }
    ) -> [FoundFile] {
        guard !cancellationRequested() else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            return []
        }

        var files: [FoundFile] = []
        while !cancellationRequested() {
            guard let item = enumerator.nextObject() else { break }
            guard !cancellationRequested() else { break }
            guard let fileURL = item as? URL,
                  let values = try? fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ) else {
                continue
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
            let resolvedURL = fileURL.resolvingSymlinksInPath()
            guard (try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true else { continue }
            files.append(FoundFile(source: fileURL, resolved: resolvedURL))
        }
        return files
    }

    /// Leichter Teil: das Scan-Ergebnis in den Main-Actor-isolierten
    /// `@Published`-State übernehmen.
    public func applyScannedFolder(
        _ scanned: ScannedFolder,
        importToken: ImportToken? = nil
    ) async {
        if AudioFile.taskCancellationRequested() { return }
        if let importToken, !isCurrentImport(importToken) { return }
        let expectedCoverRevision = importToken?.coverRevision ?? coverRevision
        if coverRevision == expectedCoverRevision, !isCoverSuppressed,
           coverImage == nil, coverPath == nil,
           let artworkData = scanned.embeddedArtwork {
            coverImage = NSImage(data: artworkData)
            coverPath = nil
            // Rohdaten merken (siehe processIncomingFiles): nur so landet ein
            // eingebettetes Cover ohne separate Bilddatei auch im Output.
            embeddedCoverData = artworkData
            isCoverSuppressed = false
        }
        // Cover-Suche nicht erneut (schon im Scan erledigt) — sonst liefe sie hier
        // auf dem Main-Thread über alle Dateien.
        await processIncomingFiles(
            scanned.audioFiles,
            skipCoverExtraction: true,
            importToken: importToken,
            sourceFolderForCLI: scanned.sourceURL
        )
        if coverRevision == expectedCoverRevision,
           !isCoverSuppressed,
           !scanned.imageURLs.isEmpty,
           let url = findLargestImage(from: scanned.imageURLs) {
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
        guard let image = NSImage(contentsOf: url) else { return false }
        coverRevision &+= 1
        invalidateArtworkWork()
        self.coverImage = resizeImage(image, maxDimension: 2000); self.coverPath = url.path
        // Gewählte Datei hat Vorrang vor eingebettetem Artwork.
        self.embeddedCoverData = nil
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

    /// Lädt Dauer und Kapiteltitel über die seit macOS 13 vorgesehenen
    /// AVFoundation-Async-Properties. Fehlerhafte oder nicht lesbare Tags
    /// verhindern den Import nicht; sie fallen auf sichere Standardwerte zurück.
    /// `sourceURL` weglassen heißt: der sichtbare Pfad ist die Datei selbst.
    public init(url: URL, sourceURL: URL? = nil) async {
        self.url = url
        self.sourceURL = sourceURL ?? url
        self.startTime = 0
        let fallbackTitle = (sourceURL ?? url).deletingPathExtension().lastPathComponent
        guard !Self.taskCancellationRequested() else {
            self.duration = 0
            self.chapterTitle = fallbackTitle
            return
        }
        let asset = AVAsset(url: url)
        // CMTimeGetSeconds kann NaN/Infinity liefern (korrupte/unlesbare Datei).
        // An der Quelle auf einen endlichen, nicht-negativen Wert klemmen — sonst
        // crashen spätere Int()-Casts (Int(NaN)) und Divisionen durch die Dauer.
        let loadedDuration = try? await asset.load(.duration)
        self.duration = AudioFile.sanitizeDuration(loadedDuration.map(CMTimeGetSeconds) ?? 0)
        guard !Self.taskCancellationRequested() else {
            self.chapterTitle = fallbackTitle
            return
        }
        let metadata = (try? await asset.load(.metadata)) ?? []
        guard !Self.taskCancellationRequested() else {
            self.chapterTitle = fallbackTitle
            return
        }
        self.chapterTitle = await AudioFile.findRobustTag(for: "title", in: metadata)
            ?? fallbackTitle
    }
    public init(url: URL, startTime: TimeInterval, duration: TimeInterval,
                chapterTitle: String, sourceURL: URL? = nil) {
        self.url = url
        self.sourceURL = sourceURL ?? url
        self.startTime = AudioFile.sanitizeDuration(startTime)
        self.duration = AudioFile.sanitizeDuration(duration)
        self.chapterTitle = chapterTitle
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
