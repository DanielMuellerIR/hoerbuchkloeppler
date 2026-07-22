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

public class ConversionSession: ObservableObject, Identifiable {
    public let id = UUID()
    public let metadataGroup = DispatchGroup()
    public init() {}
    @Published public var settings = SettingsManager.shared.loadSettings()
    
    @Published public var audioFiles: [AudioFile] = [] {
        didSet { if audioFiles.isEmpty { clearMetadata() } }
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
    private var cliSourceFolderURL: URL?
    private var cliRepresentedFileIDs = Set<UUID>()
    private var cliRepresentedChapterTitles: [UUID: String] = [:]
    @Published public var title: String = ""
    @Published public var author: String = ""
    @Published public var genre: String = "Hörbuch"
    
    // --- KONVERSION STATUS & LOGGING ---
    @Published public var isConverting: Bool = false
    @Published public var showOverlay: Bool = false
    @Published public var progress: Double = 0.0
    @Published public var conversionStatus: String = "Bereit"
    /// Ergebnis des letzten Konvertierungslaufs (nil = noch nicht beendet,
    /// true = erfolgreich, false = mit Fehler/abgebrochen). Erlaubt der CLI
    /// einen korrekten Exit-Code statt blind "Erfolg" zu melden.
    public var lastConversionSucceeded: Bool?

    private let conversionContextLock = NSLock()
    private var activeConversionContext: ConversionContext?

    /// Startet einen neuen Lauf und macht einen eventuell noch auslaufenden
    /// Vorgänger ungültig. Dessen spätere Completion darf den neuen UI-State
    /// dadurch nicht mehr überschreiben.
    func beginConversionRun() -> ConversionContext {
        let context = ConversionContext()
        conversionContextLock.lock()
        let previous = activeConversionContext
        activeConversionContext = context
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

    func endConversion(_ id: UUID) {
        conversionContextLock.lock()
        if activeConversionContext?.id == id { activeConversionContext = nil }
        conversionContextLock.unlock()
    }
    
    // KORREKTUR: Strukturierte Logs für das Terminal-Interface
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

    // NEU: Thread-sicheres Loggen mit Typen und Reverse-Order
    public func addLog(_ message: String, type: LogType = .info) {
        let entry = LogEntry(type: type, message: message, date: Date())
        DispatchQueue.main.async {
            self.eventLogs.append(entry) // KORREKTUR: Jetzt anhängen (unten), nicht oben einfügen
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
        clearMetadata()
        self.showOverlay = false
        self.isConverting = false
        self.progress = 0.0
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
                let encodingsToTry: [(name: String, encoding: String.Encoding)] = [
                    ("UTF-8", .utf8), ("Mac OS Roman", String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0800)))),
                    ("ISO-8859-1 / Windows-1252", .isoLatin1), ("ASCII", .ascii)
                ]
                var decodedText: String?
                for attempt in encodingsToTry {
                    if let text = String(data: data, encoding: attempt.encoding) {
                        decodedText = text; break
                    }
                }
                self.updateInfoText(decodedText ?? "Dekodierung fehlgeschlagen.", token: token)
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

    public var startTime: Date?
    public var processedSecondsAtStart: TimeInterval?
    public var totalDuration: TimeInterval { audioFiles.reduce(0) { $0 + $1.duration } }

    public func clearMetadata() {
        self.title = ""; self.author = ""; self.genre = "Hörbuch"
        self.coverImage = nil; self.coverPath = nil; self.embeddedCoverData = nil
        self.titleCandidates = []; self.authorCandidates = []
        self.showSelectionUI = false
        invalidateArtworkWork()
    }

    /// Markiert einen neuen GUI-Import. Langsame Antworten eines vorherigen
    /// Datei-/Ordner-Drops verlieren damit sofort ihre Schreibberechtigung.
    /// Nur auf dem Main-Thread aufrufen.
    public func beginImport() -> ImportToken {
        importGeneration = UUID()
        cliSourceFolderURL = nil
        cliRepresentedFileIDs = []
        cliRepresentedChapterTitles = [:]
        invalidateArtworkWork()
        return ImportToken(generation: importGeneration, coverRevision: coverRevision)
    }

    private func invalidateImportWork() {
        importGeneration = UUID()
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
        if !skipCoverExtraction && coverImage == nil && coverPath == nil {
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
                          self.artworkRequest == request,
                          self.coverRevision == expectedCoverRevision,
                          importToken.map(self.isCurrentImport) ?? true,
                          importedFileIDs.isSubset(of: Set(self.audioFiles.map(\.id))) else { return }
                    self.isPreparingArtwork = false
                    // Ein zwischenzeitlich manuell gesetztes Cover gewinnt.
                    guard self.coverImage == nil, self.coverPath == nil,
                          let foundArtwork else { return }
                    self.coverImage = foundArtwork.image
                    self.coverPath = nil
                    self.embeddedCoverData = foundArtwork.data
                }
            }
        }
        if title.isEmpty || author.isEmpty {
            if let first = audioFiles.first { importGlobalMetadata(from: first, importToken: importToken) }
        }
    }

    private func importGlobalMetadata(from file: AudioFile, importToken: ImportToken?) {
        metadataGroup.enter()
        // Die Group STARK fassen (nicht über self): wäre self beim Ausführen des
        // Blocks bereits dealloziert, liefe self?.metadataGroup.leave() ins Leere
        // → enter() ohne leave() → metadataGroup.wait() (CLI) hinge für immer.
        let group = metadataGroup
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { group.leave() }
            guard let self = self else { return }
            
            guard let miURL = FFmpegWrapper.getBinaryURL(name: "mediainfo") else {
                self.showMetadataSelection(ifCurrent: importToken)
                return
            }

            let process = Process()
            process.executableURL = miURL
            process.arguments = ["--Output=JSON", file.url.path]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                
                if data.isEmpty {
                    self.showMetadataSelection(ifCurrent: importToken)
                    return
                }
                
                guard let startIdx = data.firstIndex(of: 123), let endIdx = data.lastIndex(of: 125) else {
                    self.showMetadataSelection(ifCurrent: importToken)
                    return
                }
                let jsonDataSegment = data.subdata(in: startIdx..<(endIdx + 1))
                
                var finalJSONData: Data?
                let encodingsToTry: [(name: String, encoding: String.Encoding)] = [
                    ("UTF-8", .utf8), 
                    ("Mac OS Roman", String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0800)))), 
                    ("ISO-8859-1 / Windows-1252", .isoLatin1), 
                    ("UTF-16", .utf16)
                ]
                for attempt in encodingsToTry {
                    if let decodedString = String(data: jsonDataSegment, encoding: attempt.encoding), let dataBack = decodedString.data(using: .utf8) {
                        finalJSONData = dataBack
                        break
                    }
                }
                
                guard let validUTF8Data = finalJSONData else {
                    self.showMetadataSelection(ifCurrent: importToken)
                    return
                }
                
                let jsonObject = try JSONSerialization.jsonObject(with: validUTF8Data, options: [])
                var generalTrack: [String: Any]?
                if let dict = jsonObject as? [String: Any], 
                   let media = dict["media"] as? [String: Any], 
                   let tracks = media["track"] as? [[String: Any]] {
                    generalTrack = tracks.first(where: { $0["@type"] as? String == "General" })
                }
                
                guard let finalGeneral = generalTrack else {
                    self.showMetadataSelection(ifCurrent: importToken)
                    return
                }
                
                var foundTitles: [TagCandidate] = []
                var foundAuthors: [TagCandidate] = []
                func extractValue(for key: String) -> String? {
                    return finalGeneral[key] as? String ?? (finalGeneral[key] as? [String])?.first
                }
                
                if let album = extractValue(for: "Album") { foundTitles.append(TagCandidate(type: "MediaInfo", key: "Album", value: album)) }
                if let titleVal = extractValue(for: "Title") { foundTitles.append(TagCandidate(type: "MediaInfo", key: "Title", value: titleVal)) }
                if let performer = extractValue(for: "Performer") { foundAuthors.append(TagCandidate(type: "MediaInfo", key: "Performer", value: performer)) }
                if let albumPerf = extractValue(for: "Album_Performer") { foundAuthors.append(TagCandidate(type: "MediaInfo", key: "Album_Performer", value: albumPerf)) }
                
                DispatchQueue.main.async {
                    guard importToken.map(self.isCurrentImport) ?? true else { return }
                    self.titleCandidates = foundTitles
                    self.authorCandidates = foundAuthors

                    // Erst entscheiden, ob eine Auswahl nötig ist, dann genau
                    // einen eindeutigen Kandidaten automatisch übernehmen.
                    // Der frühere Ablauf füllte zuerst das Feld und prüfte danach
                    // auf "leer" — dadurch war die Auswahl-UI unerreichbar.
                    let resolution = Self.resolveMetadata(
                        currentTitle: self.title,
                        currentAuthor: self.author,
                        titleCandidates: foundTitles,
                        authorCandidates: foundAuthors
                    )
                    self.title = resolution.title
                    self.author = resolution.author
                    self.showSelectionUI = resolution.shouldShowSelection
                }
            } catch {
                self.showMetadataSelection(ifCurrent: importToken)
            }
        }
    }

    private func showMetadataSelection(ifCurrent importToken: ImportToken?) {
        DispatchQueue.main.async {
            guard importToken.map(self.isCurrentImport) ?? true else { return }
            self.showSelectionUI = true
        }
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
            let uniqueValues = Array(Set(candidates.map(\.value))).sorted()
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
            let ext = fileURL.pathExtension.lowercased()
            if ["mp3", "m4a", "wav", "flac", "m4b", "mp4"].contains(ext) {
                if ["m4b", "mp4"].contains(ext), let chapters = AudioFile.extractChapters(from: fileURL) { foundAudio.append(contentsOf: chapters) }
                else { foundAudio.append(AudioFile(url: fileURL)) }
            } else if ["jpg", "jpeg", "png"].contains(ext) { foundImages.append(fileURL) }
        }
        var embedded: Data? = nil
        for audioFile in foundAudio {
            if let artworkData = AudioFile.extractEmbeddedArtwork(from: audioFile.url) { embedded = artworkData; break }
        }
        return ScannedFolder(sourceURL: url, audioFiles: foundAudio, imageURLs: foundImages, embeddedArtwork: embedded)
    }

    /// Leichter Teil: das Scan-Ergebnis in den `@Published`-State übernehmen.
    /// MUSS auf dem Main-Thread laufen.
    public func applyScannedFolder(_ scanned: ScannedFolder, importToken: ImportToken? = nil) {
        if let importToken, !isCurrentImport(importToken) { return }
        let expectedCoverRevision = importToken?.coverRevision ?? coverRevision
        if coverRevision == expectedCoverRevision, coverImage == nil, coverPath == nil,
           let artworkData = scanned.embeddedArtwork {
            coverImage = NSImage(data: artworkData)
            coverPath = nil
            // Rohdaten merken (siehe processIncomingFiles): nur so landet ein
            // eingebettetes Cover ohne separate Bilddatei auch im Output.
            embeddedCoverData = artworkData
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

    public func selectCover(url: URL) {
        if let image = NSImage(contentsOf: url) {
            coverRevision &+= 1
            invalidateArtworkWork()
            self.coverImage = resizeImage(image, maxDimension: 2000); self.coverPath = url.path
            // Gewählte Datei hat Vorrang vor eingebettetem Artwork.
            self.embeddedCoverData = nil
        }
    }

    public func removeCover() {
        coverRevision &+= 1
        invalidateArtworkWork()
        coverImage = nil
        coverPath = nil
        embeddedCoverData = nil
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
