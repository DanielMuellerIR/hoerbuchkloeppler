import SwiftUI
import Foundation
import Combine
import AVFoundation
import AppKit

public struct TagCandidate: Identifiable, Equatable {
    public let id = UUID()
    public let type: String
    public let key: String
    public let value: String
    public init(type: String, key: String, value: String) { self.type = type; self.key = key; self.value = value }
}

public enum LogType {
    case info      // Standardtext (Primary Color)
    case highlight // Pfade, Tool-Outputs, Befehle (AccentColor)
    case dim       // Light gray (MediaInfo output)
}

public struct LogEntry: Identifiable {
    public let id = UUID()
    public let type: LogType
    public let message: String
    public let date: Date
    public init(type: LogType, message: String, date: Date) { self.type = type; self.message = message; self.date = date }
}

public struct SegmentStatus: Equatable {
    public let filename: String
    public var progress: Double
    public init(filename: String, progress: Double) { self.filename = filename; self.progress = progress }
}

public struct ImportToken: Equatable {
    fileprivate let generation: UUID
    fileprivate let coverRevision: UInt
}

struct MetadataResolution: Equatable {
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

    @discardableResult
    func cancel() -> Bool {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return false
        }
        cancelled = true
        let activeProcesses = Array(processes.values)
        processes.removeAll()
        lock.unlock()
        activeProcesses.forEach { if $0.isRunning { $0.terminate() } }
        return true
    }
}

public class ConversionSession: ObservableObject, Identifiable {
    public let id = UUID()
    public let metadataGroup = DispatchGroup()
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
    private let preparationContextLock = NSLock()
    private var preparationContext: PreparationContext?
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

    private let conversionContextLock = NSLock()
    private var activeConversionContext: ConversionContext?
    private var conversionHasFinished = false

    /// Beginnt einen abbrechbaren Import-/Metadatenlauf. Die GUI braucht das
    /// derzeit nicht; die CLI startet ihn vor dem synchronen Ordnerscan.
    public func beginPreparation() {
        let context = PreparationContext()
        preparationContextLock.lock()
        let previous = preparationContext
        preparationContext = context
        preparationContextLock.unlock()
        previous?.cancel()
    }

    @discardableResult
    public func cancelPreparation() -> Bool {
        preparationContextLock.lock()
        let context = preparationContext
        preparationContextLock.unlock()
        return context?.cancel() ?? false
    }

    private func currentPreparationContext() -> PreparationContext? {
        preparationContextLock.lock()
        defer { preparationContextLock.unlock() }
        return preparationContext
    }

    /// Liest Kapitel mit einem optional laufenden Vorbereitungs-Context. Die
    /// öffentliche Methode hält diese Prozessverwaltung aus `ContentView`.
    public func extractChapters(from url: URL) -> [AudioFile]? {
        let context = currentPreparationContext()
        return AudioFile.extractChaptersControlled(
            from: url,
            shouldCancel: { context?.isCancelled ?? false },
            registerProcess: { context?.register($0) ?? true },
            unregisterProcess: { context?.unregister($0) },
            log: { [weak self] in self?.addLog($0) }
        )
    }

    /// Startet einen neuen Lauf und macht einen eventuell noch auslaufenden
    /// Vorgänger ungültig. Dessen spätere Completion darf den neuen UI-State
    /// dadurch nicht mehr überschreiben.
    func beginConversionRun() -> ConversionContext {
        let context = ConversionContext()
        conversionContextLock.lock()
        let previous = activeConversionContext
        activeConversionContext = context
        conversionHasFinished = false
        conversionContextLock.unlock()
        previous?.cancel()
        return context
    }

    func currentConversionContext() -> ConversionContext? {
        conversionContextLock.lock()
        defer { conversionContextLock.unlock() }
        return activeConversionContext
    }

    func isCurrentConversion(_ id: UUID) -> Bool {
        conversionContextLock.lock()
        defer { conversionContextLock.unlock() }
        return activeConversionContext?.id == id
    }

    func hasFinishedConversion() -> Bool {
        conversionContextLock.lock()
        defer { conversionContextLock.unlock() }
        return conversionHasFinished
    }

    func endConversion(_ id: UUID) {
        conversionContextLock.lock()
        if activeConversionContext?.id == id {
            activeConversionContext = nil
            conversionHasFinished = true
        }
        conversionContextLock.unlock()
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
    /// Wird immer auf dem Main-Thread aufgerufen; der Renderer braucht deshalb
    /// keine eigene Sperre. Setzen ebenfalls nur auf dem Main-Thread (vor dem Start).
    public var logSink: ((String) -> Void)?

    /// Gibt eine fertige Zeile ins Terminal aus — über die Senke, falls gesetzt.
    /// Nur auf dem Main-Thread aufrufen.
    private func emit(_ line: String) {
        if let logSink = logSink { logSink(line) } else { print(line) }
    }

    // Thread-sicheres Loggen mit Darstellungstypen
    public func addLog(_ message: String, type: LogType = .info) {
        let entry = LogEntry(type: type, message: message, date: Date())
        DispatchQueue.main.async {
            self.eventLogs.append(entry)
            self.logString = self.eventLogs.map { $0.message }.joined(separator: "\n")
            let timeStr = ConversionSession.logDateFormatter.string(from: entry.date)
            self.emit("[\(timeStr)] \(message)")
        }
    }

    public func logVerbose(_ message: String) {
        guard settings.isVerbose else { return }
        // Verbose-Zeilen gehen bewusst nur ins Terminal, nicht ins UI-Log — sonst
        // wird die Oberfläche zugemüllt. Die Ausgabe läuft trotzdem über den
        // Main-Thread: Aufrufer sind u.a. die parallelen Encoding-Threads, deren
        // rohes print() sonst nebenläufig in die Fortschrittsanzeige der CLI
        // schreiben würde.
        DispatchQueue.main.async { self.emit("[VERBOSE] \(message)") }
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
        DispatchQueue.main.async {
            if let runID, !self.isCurrentConversion(runID) { return }
            self.segmentProgress[index] = SegmentStatus(filename: filename, progress: 0.0)
        }
    }

    public func updateSegmentProgress(index: Int, progress: Double, runID: UUID? = nil) {
        DispatchQueue.main.async {
            if let runID, !self.isCurrentConversion(runID) { return }
            if var status = self.segmentProgress[index] {
                status.progress = progress
                self.segmentProgress[index] = status
            }
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
    /// Nur auf dem Main-Thread lesen/schreiben.
    private var infoRequestToken = UUID()

    /// Nur auf dem Main-Thread aufrufen (setzt @Published-State).
    public func fetchRawMediaInfo(for file: AudioFile) {
        let token = UUID()
        self.infoRequestToken = token
        self.isFetchingInfo = true
        self.selectedFileInfoText = "Lade Informationen..."
        self.showInfoSheet = true

        DispatchQueue.global(qos: .userInitiated).async {
            // Gebündeltes mediainfo bevorzugen (getBinaryURL: Bundle -> PATH ->
            // Homebrew-Fallback). Vorher fest verdrahtete Homebrew-Pfade ließen
            // den Info-Dialog in der verteilten App ohne Homebrew scheitern,
            // obwohl mediainfo mitgeliefert wird.
            guard let miURL = FFmpegWrapper.getBinaryURL(name: "mediainfo") else {
                self.updateInfoText("❌ MediaInfo wurde auf diesem System nicht gefunden.", token: token)
                return
            }

            let process = Process()
            process.executableURL = miURL
            process.arguments = [file.url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if data.isEmpty {
                    self.updateInfoText("MediaInfo hat keine Informationen geliefert.", token: token)
                    return
                }
                self.updateInfoText(
                    Self.decodeMediaInfoText(from: data) ?? "Dekodierung fehlgeschlagen.",
                    token: token
                )
            } catch {
                self.updateInfoText("Fehler: \(error.localizedDescription)", token: token)
            }
        }
    }

    private func updateInfoText(_ text: String, token: UUID) {
        DispatchQueue.main.async {
            // Veraltete Antwort verwerfen: Der Nutzer hat inzwischen die Info
            // einer anderen Datei angefragt, deren Ergebnis gewinnen muss.
            guard token == self.infoRequestToken else { return }
            self.selectedFileInfoText = text
            self.isFetchingInfo = false
        }
    }

    static func decodeMediaInfoText(from data: Data) -> String? {
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
    /// Nur auf dem Main-Thread aufrufen.
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
    public func finishImport(_ token: ImportToken) {
        guard isCurrentImport(token), pendingImportOperations > 0 else { return }
        pendingImportOperations -= 1
        guard pendingImportOperations == 0 else { return }
        if (title.isEmpty || author.isEmpty), let first = audioFiles.first {
            importGlobalMetadata(from: first, importToken: token) { [weak self] in
                self?.finishMetadataImport(token: token, sourceFileID: first.id)
            }
        } else {
            isImporting = false
        }
    }

    private func finishMetadataImport(token: ImportToken, sourceFileID: UUID) {
        guard isCurrentImport(token) else { return }
        // Wurde gerade die Datei entfernt, deren Tags gelesen wurden, darf ihr
        // Ergebnis nicht gewinnen. Ein verbleibendes erstes Kapitel bekommt
        // genau einen neuen Versuch.
        if !audioFiles.contains(where: { $0.id == sourceFileID }),
           let first = audioFiles.first {
            importGlobalMetadata(from: first, importToken: token) { [weak self] in
                self?.finishMetadataImport(token: token, sourceFileID: first.id)
            }
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
    ) {
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
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var foundArtwork: (image: NSImage?, data: Data)?
                for file in filesToSearch {
                    if let artworkData = AudioFile.extractEmbeddedArtwork(from: file.url) {
                        foundArtwork = (NSImage(data: artworkData), artworkData)
                        break
                    }
                }
                DispatchQueue.main.async {
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
        }
        // GUI-Drops sammeln erst alle Provider und starten danach in
        // `finishImport` genau eine Metadatenabfrage. Der synchrone CLI-Pfad hat
        // keinen Import-Token und beginnt hier sofort.
        if importToken == nil, (title.isEmpty || author.isEmpty) {
            if let first = audioFiles.first { importGlobalMetadata(from: first, importToken: importToken) }
        }
    }

    private func importGlobalMetadata(
        from file: AudioFile,
        importToken: ImportToken?,
        completion: (() -> Void)? = nil
    ) {
        metadataGroup.enter()
        let group = metadataGroup
        let preparation = currentPreparationContext()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                group.leave()
                return
            }

            var candidates: (titles: [TagCandidate], authors: [TagCandidate])?
            if preparation?.isCancelled != true,
               let miURL = FFmpegWrapper.getBinaryURL(name: "mediainfo") {
                let process = Process()
                process.executableURL = miURL
                process.arguments = ["--Output=JSON", file.url.path]
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
                        candidates = Self.metadataCandidates(from: general)
                    } catch {
                        // Ein fehlender/kaputter Tag-Lauf fällt unten auf die
                        // manuelle Auswahl zurück. Abbruch zeigt keine neue UI.
                    }
                }
            }

            DispatchQueue.main.async {
                defer {
                    completion?()
                    group.leave()
                }
                guard importToken.map(self.isCurrentImport) ?? true,
                      importToken == nil || self.audioFiles.contains(where: { $0.id == file.id }),
                      preparation?.isCancelled != true else {
                    return
                }
                guard let candidates else {
                    self.showSelectionUI = true
                    return
                }
                self.titleCandidates = candidates.titles
                self.authorCandidates = candidates.authors
                let resolution = Self.resolveMetadata(
                    currentTitle: self.title,
                    currentAuthor: self.author,
                    titleCandidates: candidates.titles,
                    authorCandidates: candidates.authors
                )
                self.title = resolution.title
                self.author = resolution.author
                self.showSelectionUI = resolution.shouldShowSelection
            }
        }
    }

    static func decodeMediaInfoGeneralTrack(from data: Data) -> [String: Any]? {
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

    private static func metadataCandidates(
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

    static func resolveMetadata(
        currentTitle: String,
        currentAuthor: String,
        titleCandidates: [TagCandidate],
        authorCandidates: [TagCandidate]
    ) -> MetadataResolution {
        func resolve(current: String, candidates: [TagCandidate]) -> (String, Bool) {
            guard current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return (current, false)
            }
            let uniqueValues = Array(Set(
                candidates
                    .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )).sorted()
            return uniqueValues.count == 1 ? (uniqueValues[0], false) : (current, true)
        }

        let resolvedTitle = resolve(current: currentTitle, candidates: titleCandidates)
        let resolvedAuthor = resolve(current: currentAuthor, candidates: authorCandidates)
        return MetadataResolution(
            title: resolvedTitle.0,
            author: resolvedAuthor.0,
            shouldShowSelection: resolvedTitle.1 || resolvedAuthor.1
        )
    }

    /// Ergebnis eines Ordner-Scans. Enthält KEINEN `@Published`-State und darf daher
    /// gefahrlos auf einem Hintergrund-Thread berechnet werden.
    public struct ScannedFolder {
        public var sourceURL: URL
        public var audioFiles: [AudioFile]
        public var imageURLs: [URL]
        public var embeddedArtwork: Data?
    }

    /// Schwerer Teil des Ordner-Imports: rekursiv scannen, m4b-Kapitel via ffmpeg
    /// extrahieren, Dauern/eingebettetes Artwork lesen. Rührt **keinen**
    /// `@Published`-State an → thread-safe. In der GUI auf einen Hintergrund-Thread
    /// legen (sonst friert der Drop großer Ordner ein), dann `applyScannedFolder`
    /// auf dem Main-Thread aufrufen.
    public func scanFolder(_ url: URL) -> ScannedFolder {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return ScannedFolder(sourceURL: url, audioFiles: [], imageURLs: [], embeddedArtwork: nil)
        }
        var foundAudio: [AudioFile] = []; var foundImages: [URL] = []
        for case let fileURL as URL in enumerator {
            if currentPreparationContext()?.isCancelled == true { break }
            let ext = fileURL.pathExtension.lowercased()
            if ["mp3", "m4a", "wav", "flac", "m4b", "mp4"].contains(ext) {
                if ["m4b", "mp4"].contains(ext), let chapters = extractChapters(from: fileURL) { foundAudio.append(contentsOf: chapters) }
                else { foundAudio.append(AudioFile(url: fileURL)) }
            } else if ["jpg", "jpeg", "png"].contains(ext) { foundImages.append(fileURL) }
        }
        var embedded: Data? = nil
        for audioFile in foundAudio {
            if currentPreparationContext()?.isCancelled == true { break }
            if let artworkData = AudioFile.extractEmbeddedArtwork(from: audioFile.url) { embedded = artworkData; break }
        }
        return ScannedFolder(sourceURL: url, audioFiles: foundAudio, imageURLs: foundImages, embeddedArtwork: embedded)
    }

    /// Leichter Teil: das Scan-Ergebnis in den `@Published`-State übernehmen.
    /// MUSS auf dem Main-Thread laufen.
    public func applyScannedFolder(_ scanned: ScannedFolder, importToken: ImportToken? = nil) {
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
        processIncomingFiles(
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

    /// Synchroner Ordner-Import (CLI-Pfad + Abwärtskompatibilität): scannen + anwenden
    /// am Stück auf dem aufrufenden Thread. Die CLI ruft danach `metadataGroup.wait()`
    /// und verlässt sich darauf, dass der Import hier synchron abgeschlossen ist.
    public func addFolder(_ url: URL) {
        applyScannedFolder(scanFolder(url))
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

    public func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

public struct AudioFile: Identifiable {
    public let id = UUID()
    public let url: URL
    public let duration: TimeInterval
    public let startTime: TimeInterval
    public var chapterTitle: String
    public var name: String { url.lastPathComponent }

    public init(url: URL) {
        self.url = url
        let asset = AVAsset(url: url)
        // CMTimeGetSeconds kann NaN/Infinity liefern (korrupte/unlesbare Datei).
        // An der Quelle auf einen endlichen, nicht-negativen Wert klemmen — sonst
        // crashen spätere Int()-Casts (Int(NaN)) und Divisionen durch die Dauer.
        self.duration = AudioFile.sanitizeDuration(CMTimeGetSeconds(asset.duration))
        self.startTime = 0
        if let titleTag = AudioFile.findRobustTag(for: "title", in: asset.metadata) { self.chapterTitle = titleTag }
        else { self.chapterTitle = url.deletingPathExtension().lastPathComponent }
    }
    public init(url: URL, startTime: TimeInterval, duration: TimeInterval, chapterTitle: String) {
        self.url = url
        self.startTime = AudioFile.sanitizeDuration(startTime)
        self.duration = AudioFile.sanitizeDuration(duration)
        self.chapterTitle = chapterTitle
    }

    /// Macht eine Sekundenangabe für Berechnungen sicher: NaN/Infinity/negativ → 0.
    static func sanitizeDuration(_ seconds: TimeInterval) -> TimeInterval {
        return (seconds.isFinite && seconds >= 0) ? seconds : 0
    }
    private static func findRobustTag(for tagName: String, in metadata: [AVMetadataItem]) -> String? {
        if let commonItem = metadata.first(where: { $0.commonKey?.rawValue == tagName }) {
            if let value = commonItem.stringValue, !value.isEmpty { return value }
        }
        for item in metadata {
            guard let key = item.key else { continue }
            let keyString = String(describing: key).lowercased()
            if keyString.contains(tagName.lowercased()), let value = item.stringValue, !value.isEmpty { return value }
        }
        return nil
    }
}
