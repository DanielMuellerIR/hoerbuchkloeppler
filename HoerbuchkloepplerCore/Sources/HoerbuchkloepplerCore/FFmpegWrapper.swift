import Foundation
import AVFoundation
import CoreMedia
import Darwin

public struct ConversionPlan {
    public let groups: [[AudioFile]]
    public let outputURLs: [URL]
}

public enum ConversionCancellationOutcome {
    case noActiveConversion
    case cancelled
    case rejected
}

/// Laufbezogener Besitz aller Prozesse und temporären Dateien. Dadurch kann ein
/// Fenster nur seinen eigenen Lauf abbrechen; ein zweites Fenster bleibt
/// unangetastet. Die Sperre schließt außerdem das Rennen zwischen Start und
/// Abbruch eines Prozesses.
final class ConversionContext {
    let id = UUID()

    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var processes = Set<Process>()
    private var tempDirectories = Set<URL>()
    private var stagedOutputs = Set<URL>()

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func register(_ process: Process) {
        lock.lock()
        processes.insert(process)
        let shouldTerminate = cancelled
        lock.unlock()
        if shouldTerminate, process.isRunning { process.terminate() }
    }

    func unregister(_ process: Process) {
        lock.lock()
        processes.remove(process)
        lock.unlock()
    }

    func registerTempDirectory(_ url: URL) {
        lock.lock()
        tempDirectories.insert(url)
        let shouldRemove = cancelled
        lock.unlock()
        if shouldRemove { try? FileManager.default.removeItem(at: url) }
    }

    func removeTempDirectory(_ url: URL) {
        lock.lock()
        tempDirectories.remove(url)
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }

    func registerStagedOutput(_ url: URL) {
        lock.lock()
        stagedOutputs.insert(url)
        let shouldRemove = cancelled
        lock.unlock()
        if shouldRemove { try? FileManager.default.removeItem(at: url) }
    }

    func unregisterStagedOutput(_ url: URL) {
        lock.lock()
        stagedOutputs.remove(url)
        lock.unlock()
    }

    func discardStagedOutput(_ url: URL) {
        unregisterStagedOutput(url)
        try? FileManager.default.removeItem(at: url)
    }

    /// Führt den atomaren Commit nur aus, solange noch kein Abbruch gewonnen hat.
    /// Beim letzten Ziel wird der Lauf in derselben Sperre abgeschlossen; ein
    /// danach eintreffender Cancel darf die bereits fertige Ausgabe nicht mehr
    /// fälschlich als abgebrochen melden.
    func performCommit(isLastOutput: Bool, _ mutation: () throws -> Void) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        try mutation()
        if isLastOutput { finished = true }
        return true
    }

    /// Gibt `true` zurück, wenn dieser Aufruf den Lauf tatsächlich abgebrochen
    /// hat. Ein bereits mit dem letzten atomaren Commit abgeschlossener Lauf
    /// ignoriert einen verspäteten Cancel.
    @discardableResult
    func cancel() -> Bool {
        lock.lock()
        guard !finished, !cancelled else {
            lock.unlock()
            return false
        }
        cancelled = true
        let ownedProcesses = processes
        let ownedDirectories = tempDirectories
        let ownedStagedOutputs = stagedOutputs
        processes.removeAll()
        tempDirectories.removeAll()
        stagedOutputs.removeAll()
        lock.unlock()

        for process in ownedProcesses where process.isRunning { process.terminate() }
        for directory in ownedDirectories { try? FileManager.default.removeItem(at: directory) }
        for output in ownedStagedOutputs { try? FileManager.default.removeItem(at: output) }
        return true
    }
}

public struct FFmpegWrapper {
    private static let tempOwnerFilename = ".owner-pid"

    /// Nur reguläre, ausführbare Dateien sind startfähige Tool-Kandidaten.
    /// Ein gebündeltes Binary ohne x-Bit darf den funktionierenden PATH-Fallback
    /// nicht verdecken.
    public static func isUsableExecutable(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            return false
        }
        return true
    }

    static func resolveBinaryURL(name: String, bundledURL: URL?, pathEnvironment: String?, fallbackPaths: [String]) -> URL? {
        var candidates: [URL] = []
        if let bundledURL { candidates.append(bundledURL) }
        if let pathEnvironment {
            candidates += pathEnvironment.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent(name)
            }
        }
        candidates += fallbackPaths.map { URL(fileURLWithPath: $0) }
        return candidates.first(where: isUsableExecutable)
    }

    public static func getBinaryURL(name: String) -> URL? {
        let bundledURL = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "bin")
        let fallbackPaths = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/opt/local/bin/\(name)", "/usr/bin/\(name)", "/bin/\(name)"]
        return resolveBinaryURL(
            name: name,
            bundledURL: bundledURL,
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"],
            fallbackPaths: fallbackPaths
        )
    }

    /// Liefert nur dann eine Version, wenn der Prozess wirklich startet,
    /// erfolgreich endet und eine nichtleere Ausgabe liefert.
    public static func toolVersion(name: String) -> (url: URL, version: String)? {
        guard let url = getBinaryURL(name: name), let version = toolVersion(at: url, name: name) else { return nil }
        return (url, version)
    }

    static func toolVersion(at url: URL, name: String) -> String? {
        guard isUsableExecutable(url) else { return nil }
        let process = Process()
        process.executableURL = url
        process.arguments = name == "mediainfo" ? ["--Version"] : ["-version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                process.terminate()
                let terminateDeadline = Date().addingTimeInterval(0.5)
                while process.isRunning, Date() < terminateDeadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return nil }
            let parts = output.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            if let index = parts.firstIndex(where: { $0.lowercased() == "version" }), index + 1 < parts.count {
                return parts[index + 1].replacingOccurrences(of: ",", with: "")
            }
            if name == "mediainfo", let version = parts.first(where: { $0.hasPrefix("v") && $0.contains(".") }) {
                return version
            }
            return parts.first
        } catch {
            return nil
        }
    }

    public static func makeConversionPlan(files: [AudioFile], outputURL: URL, maxDurationHours: Int?) -> ConversionPlan {
        let groups = splitAudioFilesIfNeeded(files, maxDurationHours: maxDurationHours)
        let outputs = groups.indices.map {
            resolveOutputURL(outputURL, groupIndex: $0, splitGroupsCount: groups.count)
        }
        return ConversionPlan(groups: groups, outputURLs: outputs)
    }

    public static func convert(session: ConversionSession, outputURL: URL) {
        convert(
            session: session,
            plan: makeConversionPlan(
                files: session.audioFiles,
                outputURL: outputURL,
                maxDurationHours: session.settings.maxDurationHours
            )
        )
    }

    public static func convert(session: ConversionSession, plan: ConversionPlan) {
        // Ohne Eingabedateien gar nicht erst starten — sonst leere ffmpeg-Liste
        // und Division durch die Gruppengröße bei der Fortschrittsberechnung.
        guard !plan.groups.isEmpty, !plan.groups.flatMap({ $0 }).isEmpty,
              plan.groups.count == plan.outputURLs.count else {
            DispatchQueue.main.async {
                session.isConverting = false
                session.lastConversionSucceeded = false
                session.conversionStatus = "Keine Dateien"
                session.addLog("❌ Keine Audiodateien zum Konvertieren vorhanden.", type: .highlight)
            }
            return
        }
        let context = session.beginConversionRun()
        let plannedTotalDuration = plan.groups
            .flatMap { $0 }
            .reduce(0) { $0 + $1.duration }
        DispatchQueue.main.async {
            guard session.isCurrentConversion(context.id) else { return }
            session.showOverlay = true
            session.isConverting = true
            session.lastConversionSucceeded = nil
            session.completedOutputURLs = []
            session.conversionStatus = "Konvertierung läuft"
            session.progress = 0.0
            session.eventLogs = []
            session.logString = ""
            session.segmentProgress = [:]
            let totalHours = Int(session.totalDuration / 3600)
            let totalMinutes = Int((session.totalDuration.truncatingRemainder(dividingBy: 3600)) / 60)
            let durationStr = String(format: "%02d:%02dh", totalHours, totalMinutes)
            let channels = session.settings.isMono ? "Mono" : "Stereo"
            
            var totalSize: Int64 = 0
            for file in session.audioFiles {
                if let attr = try? FileManager.default.attributesOfItem(atPath: file.url.path),
                   let size = attr[.size] as? Int64 {
                    totalSize += size
                }
            }
            let sizeStr = session.formatFileSize(totalSize)
            let fileCount = session.audioFiles.count
            
            let titleStr = session.title.isEmpty ? "Unbekannt" : session.title
            let authorStr = session.author.isEmpty ? "Unbekannt" : session.author
            
            session.addLog("STARTE VORGANG \(titleStr) / \(authorStr), Dauer: \(durationStr)", type: .highlight)
            session.addLog("Eingangsdateien: \(fileCount) Dateien mit insgesamt \(sizeStr)", type: .info)
            session.addLog("Kodierungsparameter: \(channels) \(session.settings.sampleRate) Hz, \(session.settings.bitrate)bit/s AAC.", type: .info)
            let modeName = session.settings.useParallelEncoding ? "Performance-Modus (Parallel)" : "Standard-Modus (Sequenziell)"
            let codecInfo = "Apple AudioToolbox / Constrained Variable Bitrate"
            session.addLog("Technik: \(modeName) via \(codecInfo)", type: .info)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // Verfolgt, ob ALLE Gruppen erfolgreich waren -- nur dann ist der Lauf
            // wirklich erfolgreich (für CLI-Exit-Code + ehrliche Statusmeldung).
            var overallSuccess = true
            var completedDuration: TimeInterval = 0

            for (groupIndex, fileGroup) in plan.groups.enumerated() {
                if context.isCancelled {
                    overallSuccess = false
                    break
                }
                let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("HB_Temp_\(UUID().uuidString)")
                do {
                    try createOwnedTempDirectory(tempDir)
                } catch {
                    session.addLog("❌ Temporäres Arbeitsverzeichnis konnte nicht erstellt werden: \(error.localizedDescription)", type: .highlight)
                    overallSuccess = false
                    break
                }
                context.registerTempDirectory(tempDir)

                let finalURL = plan.outputURLs[groupIndex]
                let stagedURL = stagingOutputURL(for: finalURL)
                context.registerStagedOutput(stagedURL)
                var success = false
                let groupDuration = fileGroup.reduce(0) { $0 + $1.duration }
                let progressBase = plannedTotalDuration > 0
                    ? completedDuration / plannedTotalDuration
                    : 0
                let progressScale = plannedTotalDuration > 0
                    ? groupDuration / plannedTotalDuration
                    : 1

                if session.settings.useParallelEncoding {
                    success = performParallelConversion(
                        session: session,
                        context: context,
                        group: fileGroup,
                        tempDir: tempDir,
                        finalURL: stagedURL,
                        progressBase: progressBase,
                        progressScale: progressScale
                    )
                } else {
                    success = performSequentialConversion(
                        session: session,
                        context: context,
                        group: fileGroup,
                        tempDir: tempDir,
                        finalURL: stagedURL,
                        progressBase: progressBase,
                        progressScale: progressScale
                    )
                }

                guard success, !context.isCancelled, let size = regularFileSize(stagedURL) else {
                    context.discardStagedOutput(stagedURL)
                    if !context.isCancelled {
                        session.addLog("❌ KRITISCHER FEHLER beim Erstellen von \(finalURL.lastPathComponent). Vorgang abgebrochen.", type: .highlight)
                    }
                    context.removeTempDirectory(tempDir)
                    overallSuccess = false
                    break
                }

                // Die rein informative Analyse läuft auf der Staging-Datei. Der
                // atomare Rename bleibt damit der letzte relevante Dateischritt.
                if let miPath = getBinaryURL(name: "mediainfo"), !context.isCancelled {
                    let process = Process()
                    process.executableURL = miPath
                    process.arguments = [stagedURL.path]
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    context.register(process)
                    do {
                        defer { context.unregister(process) }
                        try process.run()
                        if context.isCancelled { process.terminate() }
                        // Erst die Pipe leeren, DANN auf Exit warten — sonst
                        // Deadlock, wenn die mediainfo-Ausgabe den Pipe-Puffer füllt.
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        if !context.isCancelled,
                           let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !output.isEmpty {
                            session.addLog("--- MediaInfo Eigenschaften ---\n" + output, type: .dim)
                            // Gilt in BEIDEN Modi: aac_at/CVBR wird von ffmpeg+mediainfo
                            // immer als 'Constant' gelabelt (verifiziert), nicht nur beim
                            // Stream-Copy. Der Audio-Stream bleibt dennoch Constrained VBR.
                            session.addLog("Hinweis: MediaInfo labelt aac_at/CVBR fälschlicherweise als 'Bitrate-Modus: Constant'. Die Audiodaten sind dennoch durchgehend variables Apple CVBR.", type: .dim)
                        }
                    } catch {
                        // Die Nachanalyse ist rein informativ und darf einen sonst
                        // gültigen Output nicht verhindern.
                        session.logVerbose("MediaInfo-Nachanalyse übersprungen: \(error.localizedDescription)")
                    }
                }

                do {
                    let committed = try context.performCommit(
                        isLastOutput: groupIndex == plan.groups.count - 1
                    ) {
                        try commitStagedOutput(stagedURL, to: finalURL)
                    }
                    guard committed else {
                        context.discardStagedOutput(stagedURL)
                        context.removeTempDirectory(tempDir)
                        overallSuccess = false
                        break
                    }
                    // rename() hat die Staging-Datei verschoben; nur noch aus
                    // dem Context austragen, nicht den neuen Zielpfad löschen.
                    context.unregisterStagedOutput(stagedURL)
                    DispatchQueue.main.async {
                        guard session.isCurrentConversion(context.id) else { return }
                        session.completedOutputURLs.append(finalURL)
                    }
                } catch {
                    context.discardStagedOutput(stagedURL)
                    session.addLog("❌ Ausgabe konnte nicht atomar übernommen werden: \(error.localizedDescription)", type: .highlight)
                    context.removeTempDirectory(tempDir)
                    overallSuccess = false
                    break
                }

                session.addLog("✅ Datei erfolgreich erstellt!", type: .highlight)
                session.addLog("Name: \(finalURL.lastPathComponent)", type: .info)
                session.addLog("Pfad: \(finalURL.path)", type: .info)
                session.addLog("Größe: \(session.formatFileSize(size))", type: .info)
                context.removeTempDirectory(tempDir)
                completedDuration += groupDuration
            }

            DispatchQueue.main.async {
                guard session.isCurrentConversion(context.id) else { return }
                session.isConverting = false
                session.progress = overallSuccess ? 1.0 : session.progress
                session.lastConversionSucceeded = overallSuccess
                if context.isCancelled {
                    session.conversionStatus = "Abgebrochen"
                } else {
                    session.conversionStatus = overallSuccess ? "Erfolgreich abgeschlossen" : "Mit Fehlern beendet"
                    session.addLog(overallSuccess ? "🏁 Alle Vorgänge beendet." : "🏁 Vorgang mit Fehlern beendet.", type: .highlight)
                }
                session.endConversion(context.id)
            }
        }
    }

    private static func runParallelTasks(group: [AudioFile], tempDir: URL, session: ConversionSession, context: ConversionContext,
                                         progressBase: Double, progressWeight: Double,
                                         extensionStr: String, showIndividualPacmans: Bool,
                                         argsProvider: @escaping (Int, AudioFile, URL) -> [String]) -> [String]? {
        // ffmpeg einmal vorab auflösen. Fehlt es, die Ursache klar benennen und
        // abbrechen — der frühere /usr/bin/false-Fallback pro Segment erzeugte
        // nur irreführende "Segment fehlgeschlagen"-Meldungen.
        guard let ffmpegURL = getBinaryURL(name: "ffmpeg") else {
            session.addLog("❌ ffmpeg wurde nicht gefunden (weder gebündelt noch im PATH/Homebrew/MacPorts). Bitte ./build.sh ausführen oder ffmpeg installieren.", type: .highlight)
            return nil
        }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let maxConcurrent = max(1, cores - 1)
        let semaphore = DispatchSemaphore(value: maxConcurrent)
        let groupQueue = DispatchQueue(label: "com.hoerbuchkloppler.parallel", attributes: .concurrent)
        let completionGroup = DispatchGroup()
        
        var results: [String] = Array(repeating: "", count: group.count)
        let lock = NSLock()
        
        class ProgressTracker {
            var progresses: [Int: Double] = [:]
            let lock = NSLock()
        }
        let tracker = ProgressTracker()
        
        DispatchQueue.main.async {
            guard session.isCurrentConversion(context.id) else { return }
            session.segmentProgress = [:]
            if !showIndividualPacmans {
                session.initSegmentProgress(index: 0, filename: "Audio-Dekodierung (WAV)", runID: context.id)
            }
        }

        for (idx, file) in group.enumerated() {
            completionGroup.enter()
            groupQueue.async {
                semaphore.wait()
                defer {
                    semaphore.signal()
                    completionGroup.leave()
                }

                if context.isCancelled {
                    return
                }
                
                let segmentURL = tempDir.appendingPathComponent("seg_\(idx).\(extensionStr)")
                let finalArgs = argsProvider(idx, file, segmentURL)
                
                if showIndividualPacmans {
                    session.initSegmentProgress(index: idx, filename: file.name, runID: context.id)
                }

                let process = Process()
                process.executableURL = ffmpegURL
                process.arguments = finalArgs
                
                context.register(process)
                defer { context.unregister(process) }
                
                session.logVerbose("Starte Segment \(idx+1): ffmpeg \(finalArgs.joined(separator: " "))")
                
                let errorPipe = Pipe()
                process.standardError = errorPipe
                let reader = errorPipe.fileHandleForReading

                // stderr fortlaufend mitschneiden: der readabilityHandler liest die
                // Daten zur Fortschrittsanzeige; ein erneutes readDataToEndOfFile()
                // im Fehlerfall käme zu spät (Daten schon konsumiert) und lieferte
                // eine leere Fehlermeldung. Deshalb hier puffern.
                let stderrBuffer = NSMutableData()
                let stderrLock = NSLock()

                reader.readabilityHandler = { fileHandle in
                    let data = fileHandle.availableData
                    if data.isEmpty { return }
                    stderrLock.lock(); stderrBuffer.append(data); stderrLock.unlock()
                    if let output = String(data: data, encoding: .utf8) {
                        if output.contains("time=") {
                            if let timeString = extractTimeFromFFmpeg(output),
                               let currentSeconds = timeToSeconds(timeString),
                               file.duration > 0 {
                                let p = min(1, max(0, currentSeconds / file.duration))
                                tracker.lock.lock()
                                tracker.progresses[idx] = p
                                let totalP = tracker.progresses.values.reduce(0, +) / Double(group.count)
                                tracker.lock.unlock()
                                DispatchQueue.main.async {
                                    guard session.isCurrentConversion(context.id) else { return }
                                    session.progress = max(session.progress, mappedProgress(
                                        base: progressBase,
                                        weight: progressWeight,
                                        phaseProgress: totalP
                                    ))
                                }
                                if showIndividualPacmans {
                                    session.updateSegmentProgress(index: idx, progress: p, runID: context.id)
                                } else {
                                    session.updateSegmentProgress(index: 0, progress: totalP, runID: context.id)
                                }
                            }
                        }
                    }
                }

                do {
                    try process.run()
                    // Abbruch-Race schließen: Wird zwischen dem Cancel-Check oben und
                    // diesem Start abgebrochen, hat cancelConversion den Prozess evtl.
                    // noch nicht laufen sehen (isRunning war false) und übersprungen.
                    // Jetzt läuft er — sofort erneut prüfen und ggf. beenden, damit kein
                    // ungetrackter ffmpeg nach dem "Abbruch" voll durchläuft.
                    if context.isCancelled { process.terminate() }
                    process.waitUntilExit()
                    reader.readabilityHandler = nil
                    // Letzten, evtl. noch im Puffer liegenden stderr-Rest nachlesen,
                    // damit die Fehlermeldung vollständig ist.
                    let rest = reader.availableData
                    if !rest.isEmpty { stderrLock.lock(); stderrBuffer.append(rest); stderrLock.unlock() }
                    if context.isCancelled { return }
                    if process.terminationStatus == 0 {
                        var fileIsValid = false
                        if let attr = try? FileManager.default.attributesOfItem(atPath: segmentURL.path),
                           let size = attr[.size] as? Int64, size > 0 {
                            fileIsValid = true
                        }
                        
                        if fileIsValid {
                            lock.lock()
                            results[idx] = segmentURL.path
                            let finishedCount = results.filter { !$0.isEmpty }.count
                            lock.unlock()
                            tracker.lock.lock()
                            tracker.progresses[idx] = 1
                            let totalProgress = tracker.progresses.values.reduce(0, +) / Double(group.count)
                            tracker.lock.unlock()
                            DispatchQueue.main.async {
                                guard session.isCurrentConversion(context.id) else { return }
                                session.progress = max(session.progress, mappedProgress(
                                    base: progressBase,
                                    weight: progressWeight,
                                    phaseProgress: totalProgress
                                ))
                                if showIndividualPacmans {
                                    session.updateSegmentProgress(index: idx, progress: 1.0, runID: context.id)
                                } else if finishedCount == group.count {
                                    session.updateSegmentProgress(index: 0, progress: 1.0, runID: context.id)
                                }
                            }
                        } else {
                            session.addLog("❌ KRITISCHER FEHLER: Zieldatei Segment \(idx+1) ist leer oder fehlt.", type: .highlight)
                        }
                    } else {
                        stderrLock.lock(); let errorData = stderrBuffer as Data; stderrLock.unlock()
                        let errorString = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let errorMessage = (errorString?.isEmpty == false) ? errorString! : "Unbekannter FFmpeg Fehler"
                        session.addLog("❌ Segment \(idx+1) fehlgeschlagen (Exit-Code \(process.terminationStatus)):\n\(errorMessage)", type: .highlight)
                    }
                } catch {
                    // Auch im Fehlerfall (process.run() wirft) den Handler lösen —
                    // sonst hält der readabilityHandler das Pipe-Ende dauerhaft fest
                    // (Handler-/Dateideskriptor-Leck über viele Segmente hinweg).
                    reader.readabilityHandler = nil
                    if !context.isCancelled {
                        session.addLog("❌ Prozess-Fehler bei Segment \(idx+1): \(error.localizedDescription)", type: .highlight)
                    }
                }
            }
        }
        completionGroup.wait()
        return results.allSatisfy { !$0.isEmpty } ? results : nil
    }

    /// Schreibt die concat-Liste (`audio_list.txt`) und die FFMETADATA-
    /// Kapiteldatei (`chapters.txt`) nach tempDir. Gibt `false` zurück, wenn ein
    /// Schreibvorgang fehlschlägt — sonst liefe ffmpeg mit fehlender Steuerdatei
    /// weiter und meldete einen irreführenden Fehler. Pfade werden fürs
    /// concat-Format escaped (einfaches Anführungszeichen → `'\''`).
    /// Baut den FFMETADATA-Inhalt (`chapters.txt`) für eine Kapitelgruppe.
    /// Kapitel liegen hintereinander: jedes beginnt, wo das vorherige endet.
    ///
    /// Bewusst eine reine Funktion ohne Datei-I/O — so ist die Kapitel-Arithmetik
    /// (Grenzen, Escaping) testbar, ohne echte Dateien schreiben zu müssen.
    static func buildChapterMetadata(group: [AudioFile]) -> String {
        var metaContent = ";FFMETADATA1\n"
        var currentTime: TimeInterval = 0
        for file in group {
            metaContent += "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(Int(currentTime * 1000))\nEND=\(Int((currentTime + file.duration) * 1000))\ntitle=\(escapeFFMetadata(file.chapterTitle))\n"
            currentTime += file.duration
        }
        return metaContent
    }

    private static func writeConcatAndChapters(validPaths: [String], group: [AudioFile], listFile: URL, metaFile: URL, session: ConversionSession) -> Bool {
        let fileListContent = validPaths.map { "file '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
        let metaContent = buildChapterMetadata(group: group)
        do {
            try fileListContent.write(to: listFile, atomically: true, encoding: .utf8)
            try metaContent.write(to: metaFile, atomically: true, encoding: .utf8)
            return true
        } catch {
            session.addLog("❌ KRITISCHER FEHLER: Steuerdateien konnten nicht geschrieben werden: \(error.localizedDescription)", type: .highlight)
            return false
        }
    }

    /// Gemeinsamer MP4/M4B-Mux-Aufbau für Standard- und Parallelmodus. Nur die
    /// Audio-Codecargumente unterscheiden sich; Inputs, Metadaten, Cover-Mapping
    /// und Ausgabe müssen in beiden Pfaden identisch bleiben.
    private static func finalMuxArguments(
        listFile: URL,
        metaFile: URL,
        coverInput: String?,
        audioCodecArguments: [String],
        session: ConversionSession,
        finalURL: URL
    ) -> [String] {
        var arguments = [
            "-nostdin", "-y", "-f", "concat", "-safe", "0", "-i", listFile.path,
            "-i", metaFile.path
        ]
        if let coverInput { arguments += ["-i", coverInput] }
        arguments += audioCodecArguments
        arguments += [
            "-map", "0:a", "-map_metadata", "1",
            "-metadata", "title=\(session.title)",
            "-metadata", "album=\(session.title)",
            "-metadata", "artist=\(session.author)",
            "-metadata", "genre=\(session.genre)"
        ]
        if coverInput != nil {
            arguments += ["-map", "2:0", "-c:v", "copy", "-disposition:v", "attached_pic"]
        }
        arguments.append(finalURL.path)
        return arguments
    }

    private static func performSequentialConversion(
        session: ConversionSession,
        context: ConversionContext,
        group: [AudioFile],
        tempDir: URL,
        finalURL: URL,
        progressBase: Double,
        progressScale: Double
    ) -> Bool {
        let wavPaths = runParallelTasks(group: group, tempDir: tempDir, session: session, context: context, progressBase: progressBase, progressWeight: progressScale * 0.2, extensionStr: "wav", showIndividualPacmans: false) { _, file, url in
            FFmpegWrapper.getArgsForStandardSlicing(file: file, url: url, session: session)
        }
        guard let validPaths = wavPaths else { return false }
        let listFile = tempDir.appendingPathComponent("audio_list.txt")
        let metaFile = tempDir.appendingPathComponent("chapters.txt")
        guard writeConcatAndChapters(validPaths: validPaths, group: group, listFile: listFile, metaFile: metaFile, session: session) else { return false }
        let coverInput = resolveCoverInputPath(session: session, tempDir: tempDir)
        let args = finalMuxArguments(
            listFile: listFile,
            metaFile: metaFile,
            coverInput: coverInput,
            audioCodecArguments: [
                "-c:a", "aac_at", "-aac_at_mode", "cvbr",
                "-b:a", session.settings.bitrate,
                "-ar", "\(session.settings.sampleRate)",
                "-ac", session.settings.isMono ? "1" : "2"
            ],
            session: session,
            finalURL: finalURL
        )
        return runFinalProcess(
            args: args,
            session: session,
            context: context,
            progressBase: progressBase + progressScale * 0.2,
            progressWeight: progressScale * 0.8,
            phaseDuration: group.reduce(0) { $0 + $1.duration },
            logMessage: "🛠️ Starte komplette Apple CVBR Kodierung...",
            pacmanTitle: "Apple AAC Encoding"
        )
    }

    private static func performParallelConversion(
        session: ConversionSession,
        context: ConversionContext,
        group: [AudioFile],
        tempDir: URL,
        finalURL: URL,
        progressBase: Double,
        progressScale: Double
    ) -> Bool {
        let aacPaths = runParallelTasks(group: group, tempDir: tempDir, session: session, context: context, progressBase: progressBase, progressWeight: progressScale * 0.9, extensionStr: "m4a", showIndividualPacmans: true) { _, file, url in
            FFmpegWrapper.getArgsForParallelEncoding(file: file, url: url, session: session)
        }
        guard let validPaths = aacPaths else { return false }
        let listFile = tempDir.appendingPathComponent("audio_list.txt")
        let metaFile = tempDir.appendingPathComponent("chapters.txt")
        guard writeConcatAndChapters(validPaths: validPaths, group: group, listFile: listFile, metaFile: metaFile, session: session) else { return false }
        let coverInput = resolveCoverInputPath(session: session, tempDir: tempDir)
        let args = finalMuxArguments(
            listFile: listFile,
            metaFile: metaFile,
            coverInput: coverInput,
            audioCodecArguments: ["-c:a", "copy"],
            session: session,
            finalURL: finalURL
        )
        return runFinalProcess(
            args: args,
            session: session,
            context: context,
            progressBase: progressBase + progressScale * 0.9,
            progressWeight: progressScale * 0.1,
            phaseDuration: group.reduce(0) { $0 + $1.duration },
            logMessage: "🛠️ Finaler Stream-Copy & MP4-Muxing gestartet...",
            pacmanTitle: "Finaler Zusammenbau"
        )
    }

    private static func runFinalProcess(
        args: [String],
        session: ConversionSession,
        context: ConversionContext,
        progressBase: Double,
        progressWeight: Double,
        phaseDuration: TimeInterval,
        logMessage: String,
        pacmanTitle: String
    ) -> Bool {
        DispatchQueue.main.async {
            guard session.isCurrentConversion(context.id) else { return }
            session.segmentProgress = [:]
            session.initSegmentProgress(index: 0, filename: pacmanTitle, runID: context.id)
        }
        if context.isCancelled { return false }
        session.addLog(logMessage, type: .highlight)
        
        // Fehlendes ffmpeg klar melden statt (wie früher) /usr/bin/false zu starten,
        // dessen Exit-Code nur eine irreführende Fehlermeldung produzierte.
        guard let ffmpegURL = getBinaryURL(name: "ffmpeg") else {
            session.addLog("❌ ffmpeg wurde nicht gefunden (weder gebündelt noch im PATH/Homebrew/MacPorts). Bitte ./build.sh ausführen oder ffmpeg installieren.", type: .highlight)
            return false
        }
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = args
        let pipe = Pipe()
        process.standardError = pipe
        session.logVerbose("Führe Final-Prozess aus: ffmpeg \(args.joined(separator: " "))")
        
        context.register(process)
        defer { context.unregister(process) }
        
        do {
            try process.run()
            if context.isCancelled { process.terminate() }
            let reader = pipe.fileHandleForReading
            
            reader.readabilityHandler = { fileHandle in
                let data = fileHandle.availableData
                if data.isEmpty { return }
                if let output = String(data: data, encoding: .utf8) {
                    if let timeString = extractTimeFromFFmpeg(output),
                       let currentSeconds = timeToSeconds(timeString) {
                        DispatchQueue.main.async {
                            guard session.isCurrentConversion(context.id) else { return }
                            guard phaseDuration > 0 else { return }
                            let p = min(1, max(0, currentSeconds / phaseDuration))
                            session.progress = mappedProgress(
                                base: progressBase,
                                weight: progressWeight,
                                phaseProgress: p
                            )
                            session.updateSegmentProgress(index: 0, progress: p, runID: context.id)
                        }
                    }
                }
            }
            
            process.waitUntilExit()
            reader.readabilityHandler = nil
            if context.isCancelled { return false }
            if process.terminationStatus == 0 {
                DispatchQueue.main.async {
                    guard session.isCurrentConversion(context.id) else { return }
                    session.progress = mappedProgress(
                        base: progressBase,
                        weight: progressWeight,
                        phaseProgress: 1
                    )
                }
                session.updateSegmentProgress(index: 0, progress: 1.0, runID: context.id)
                return true
            }
            session.addLog("❌ KRITISCHER FEHLER beim finalen Zusammenfügen. Exit-Code: \(process.terminationStatus)", type: .highlight)
            return false
        } catch {
            if !context.isCancelled {
                session.addLog("❌ KRITISCHER FEHLER: \(error.localizedDescription)", type: .highlight)
            }
            return false
        }
    }

    /// Maskiert einen Wert fürs FFMETADATA-Format. `\`, `=`, `;` und `#` werden
    /// mit Backslash escaped; Zeilenumbrüche werden zu Leerzeichen (ein
    /// Kapiteltitel ist einzeilig). Ohne das zerstört z.B. ein Newline im
    /// Kapiteltitel die gesamte chapters.txt.
    ///
    /// Sonderfall Backslash am Zeilenende: ffmpegs FFMETADATA-Leser behandelt
    /// JEDEN Backslash am Zeilenende als Zeilenfortsetzung — auch den per `\\`
    /// maskierten — und würde die folgende `[CHAPTER]`-Zeile verschlucken (ein
    /// Kapitel ginge verloren). Ein FFMETADATA-Wert darf also nicht auf einen
    /// Backslash enden; abschließende Backslashes werden daher entfernt
    /// (ffmpeg kann sie ohnehin nicht verlustfrei zurücklesen).
    static func escapeFFMetadata(_ value: String) -> String {
        var out = ""
        for ch in value {
            switch ch {
            case "\\", "=", ";", "#": out.append("\\"); out.append(ch)
            case "\n", "\r": out.append(" ")
            default: out.append(ch)
            }
        }
        while out.hasSuffix("\\") { out.removeLast() }
        return out
    }

    /// Liefert den Dateipfad des Covers für ffmpeg. Bevorzugt eine vom Nutzer
    /// gewählte Bilddatei (`coverPath`). Liegt nur eingebettetes Artwork vor
    /// (`embeddedCoverData`), wird dieses in `tempDir` geschrieben und sein Pfad
    /// zurückgegeben — sonst würde ein nur eingebettetes Cover im Output fehlen.
    private static func resolveCoverInputPath(session: ConversionSession, tempDir: URL) -> String? {
        if let path = session.coverPath {
            // Existiert die gewählte Cover-Datei nicht mehr (verschoben/gelöscht),
            // nicht die ganze Konvertierung an ffmpeg scheitern lassen, sondern
            // ohne Cover fortfahren (ggf. fällt embeddedCoverData ein).
            if FileManager.default.fileExists(atPath: path) { return path }
            session.addLog("⚠️ Cover-Datei nicht mehr vorhanden, fahre ohne dieses Cover fort: \(path)", type: .info)
        }
        if let data = session.embeddedCoverData {
            let coverURL = tempDir.appendingPathComponent("cover.img")
            do {
                try data.write(to: coverURL)
                return coverURL.path
            } catch {
                session.addLog("⚠️ Eingebettetes Cover konnte nicht zwischengespeichert werden — Output ohne Cover.", type: .info)
                return nil
            }
        }
        return nil
    }

    static func resolveOutputURL(_ url: URL, groupIndex: Int, splitGroupsCount: Int) -> URL {
        if splitGroupsCount <= 1 { return url }
        let baseName = url.deletingPathExtension().lastPathComponent
        let fileExt = url.pathExtension
        let parentDir = url.deletingLastPathComponent()
        return parentDir.appendingPathComponent("\(baseName)-\(String(format: "%02d", groupIndex + 1))").appendingPathExtension(fileExt)
    }

    static func stagingOutputURL(for finalURL: URL, id: UUID = UUID()) -> URL {
        let parent = finalURL.deletingLastPathComponent()
        let basename = finalURL.deletingPathExtension().lastPathComponent
        let ext = finalURL.pathExtension.isEmpty ? "m4b" : finalURL.pathExtension
        return parent.appendingPathComponent(".\(basename).partial-\(id.uuidString)").appendingPathExtension(ext)
    }

    static func regularFileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int64 else { return nil }
        return size > 0 ? size : nil
    }

    static func mappedProgress(base: Double, weight: Double, phaseProgress: Double) -> Double {
        min(1, max(0, base + weight * min(1, max(0, phaseProgress))))
    }

    static func isNonEmptyRegularFile(_ url: URL) -> Bool {
        regularFileSize(url) != nil
    }

    /// POSIX rename ersetzt eine bestehende reguläre Datei auf demselben
    /// Dateisystem atomar. Bis zu diesem Punkt bleibt das bestätigte Original
    /// unangetastet; bei Fehlern wird nur die eindeutige Partial-Datei entfernt.
    static func commitStagedOutput(_ stagedURL: URL, to finalURL: URL) throws {
        guard isNonEmptyRegularFile(stagedURL) else { throw CocoaError(.fileReadCorruptFile) }
        let result = stagedURL.path.withCString { source in
            finalURL.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func splitAudioFilesIfNeeded(_ files: [AudioFile], maxDurationHours: Int?) -> [[AudioFile]] {
        guard let maxHours = maxDurationHours, maxHours > 0 else { return [files] }
        var result: [[AudioFile]] = []; var currentGroup: [AudioFile] = []; var currentDuration: TimeInterval = 0
        for file in files {
            if currentDuration + file.duration <= Double(maxHours) * 3600 {
                currentGroup.append(file); currentDuration += file.duration
            } else {
                if !currentGroup.isEmpty { result.append(currentGroup) }
                currentGroup = [file]; currentDuration = file.duration
            }
        }
        if !currentGroup.isEmpty { result.append(currentGroup) }
        return result
    }


    @discardableResult
    public static func cancelConversion(
        session: ConversionSession
    ) -> ConversionCancellationOutcome {
        guard let context = session.currentConversionContext() else {
            return session.hasFinishedConversion()
                ? .rejected
                : .noActiveConversion
        }
        guard context.cancel() else { return .rejected }

        DispatchQueue.main.async {
            guard session.isCurrentConversion(context.id) else { return }
            // Der Worker setzt den definitiven Abschluss erst, nachdem alle
            // Prozesse beendet und alle laufbezogenen Dateien entfernt sind.
            session.conversionStatus = "Abbruch läuft …"
            session.addLog("🛑 Vorgang wird abgebrochen und bereinigt.", type: .info)
        }
        return .cancelled
    }

    static func createOwnedTempDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let owner = String(ProcessInfo.processInfo.processIdentifier)
        try owner.write(
            to: url.appendingPathComponent(tempOwnerFilename),
            atomically: true,
            encoding: .utf8
        )
    }

    static func temporaryDirectoryHasLiveOwner(_ url: URL) -> Bool {
        let marker = url.appendingPathComponent(tempOwnerFilename)
        guard let text = try? String(contentsOf: marker, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return false }
        return Darwin.kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    public static func cleanupOldTempDirectories() {
        let fileManager = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let contents = try? fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.creationDateKey], options: []) else { return }
        
        let now = Date()
        let oneDayAgo = now.addingTimeInterval(-24 * 3600)
        
        for url in contents {
            if url.lastPathComponent.hasPrefix("HB_Temp_") {
                if let resourceValues = try? url.resourceValues(forKeys: [.creationDateKey]),
                   let creationDate = resourceValues.creationDate {
                    if creationDate < oneDayAgo, !temporaryDirectoryHasLiveOwner(url) {
                        try? fileManager.removeItem(at: url)
                    }
                }
            }
        }
    }

    static func timeToSeconds(_ time: String) -> TimeInterval? {
        let parts = time.split(separator: ":")
        if parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) {
            return (h * 3600) + (m * 60) + s
        }
        return nil
    }

    static func extractTimeFromFFmpeg(_ output: String) -> String? {
        let pattern = "time=(\\d{2}:\\d{2}:\\d{2}.\\d{2})"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)) {
            if let range = Range(match.range(at: 1), in: output) {
                return String(output[range])
            }
        }
        return nil
    }
}

extension FFmpegWrapper {
    static func getArgsForStandardSlicing(file: AudioFile, url: URL, session: ConversionSession) -> [String] {
        // Zwischen-WAV direkt auf die Ziel-Abtastrate slicen statt hart auf 44100.
        // Sonst würde z.B. bei Ziel 48000 zweimal resampelt (Quelle→44100 beim
        // Slicen, 44100→48000 beim finalen Encode) — unnötiger Qualitätsverlust.
        // Ebenso auf die Ziel-KANALZAHL slicen (nicht hart Stereo): unkomprimiertes
        // WAV ist der Temp-Treiber (Standard-Modus hält ALLE Slices gleichzeitig),
        // und für ein Mono-Hörbuch (Default) halbiert Mono-Slicing den Temp-Bedarf.
        // Der finale `-ac`-Downmix bleibt identisch, nur eben schon beim Slicen.
        return ["-nostdin", "-y", "-ss", "\(file.startTime)", "-t", "\(file.duration)", "-i", file.url.path, "-vn", "-acodec", "pcm_s16le", "-ar", "\(session.settings.sampleRate)", "-ac", session.settings.isMono ? "1" : "2", url.path]
    }

    static func getArgsForParallelEncoding(file: AudioFile, url: URL, session: ConversionSession) -> [String] {
        return ["-nostdin", "-y", "-ss", "\(file.startTime)", "-t", "\(file.duration)", "-i", file.url.path, "-vn", "-c:a", "aac_at", "-aac_at_mode", "cvbr", "-b:a", session.settings.bitrate, "-ar", "\(session.settings.sampleRate)", "-ac", session.settings.isMono ? "1" : "2", url.path]
    }
}
