import Foundation
import AVFoundation
import CoreMedia

public struct FFmpegWrapper {
    private static var activeProcesses = Set<Process>()
    private static let registryLock = NSLock()
    
    private static var isCancelled = false
    private static let cancellationLock = NSLock()
    
    public static func setIsCancelled(_ value: Bool) {
        cancellationLock.lock()
        isCancelled = value
        cancellationLock.unlock()
    }
    
    public static func getIsCancelled() -> Bool {
        cancellationLock.lock()
        let val = isCancelled
        cancellationLock.unlock()
        return val
    }

    private static func registerProcess(_ process: Process) {
        registryLock.lock()
        activeProcesses.insert(process)
        registryLock.unlock()
    }
    
    private static func unregisterProcess(_ process: Process) {
        registryLock.lock()
        activeProcesses.remove(process)
        registryLock.unlock()
    }

    // Registry der aktiven Temp-Verzeichnisse, damit ein Abbruch (besonders der
    // CLI-SIGINT mit sofortigem exit) die teils großen Zwischen-WAVs aufräumt.
    private static var activeTempDirs = Set<URL>()

    private static func registerTempDir(_ url: URL) {
        registryLock.lock()
        activeTempDirs.insert(url)
        registryLock.unlock()
    }

    /// Entfernt ein Temp-Verzeichnis und trägt es aus der Registry aus.
    private static func removeTempDir(_ url: URL) {
        registryLock.lock()
        activeTempDirs.remove(url)
        registryLock.unlock()
        try? FileManager.default.removeItem(at: url)
    }

    public static func getBinaryURL(name: String) -> URL? {
        if let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "bin") {
            return url
        }
        
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            let paths = pathEnv.split(separator: ":").map { String($0) }
            for dir in paths {
                let fileURL = URL(fileURLWithPath: dir).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    return fileURL
                }
            }
        }
        
        // Übliche Installationsorte: Homebrew (Apple Silicon + Intel), MacPorts, System.
        let fallbackPaths = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/opt/local/bin/\(name)", "/usr/bin/\(name)", "/bin/\(name)"]
        for path in fallbackPaths {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    public static func convert(session: ConversionSession, outputURL: URL) {
        setIsCancelled(false)
        // Ohne Eingabedateien gar nicht erst starten — sonst leere ffmpeg-Liste
        // und Division durch die Gruppengröße bei der Fortschrittsberechnung.
        guard !session.audioFiles.isEmpty else {
            DispatchQueue.main.async {
                session.isConverting = false
                session.lastConversionSucceeded = false
                session.conversionStatus = "Keine Dateien"
                session.addLog("❌ Keine Audiodateien zum Konvertieren vorhanden.", type: .highlight)
            }
            return
        }
        DispatchQueue.main.async {
            session.showOverlay = true
            session.isConverting = true
            session.lastConversionSucceeded = nil
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
            let splitGroups = splitAudioFilesIfNeeded(session.audioFiles, maxDurationHours: session.settings.maxDurationHours)
            // Verfolgt, ob ALLE Gruppen erfolgreich waren -- nur dann ist der Lauf
            // wirklich erfolgreich (für CLI-Exit-Code + ehrliche Statusmeldung).
            var overallSuccess = true

            for (groupIndex, fileGroup) in splitGroups.enumerated() {
                let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("HB_Temp_\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                registerTempDir(tempDir)

                let finalURL = resolveOutputURL(outputURL, groupIndex: groupIndex, splitGroupsCount: splitGroups.count)
                var success = false

                if session.settings.useParallelEncoding {
                    success = performParallelConversion(session: session, group: fileGroup, tempDir: tempDir, finalURL: finalURL)
                } else {
                    success = performSequentialConversion(session: session, group: fileGroup, tempDir: tempDir, finalURL: finalURL)
                }

                if success && FileManager.default.fileExists(atPath: finalURL.path) {
                    do {
                        let attr = try FileManager.default.attributesOfItem(atPath: finalURL.path)
                        let size = attr[.size] as? Int64 ?? 0
                        
                        if size > 0 {
                            if let miPath = getBinaryURL(name: "mediainfo") {
                                let process = Process()
                                process.executableURL = miPath
                                process.arguments = [finalURL.path]
                                let pipe = Pipe()
                                process.standardOutput = pipe
                                do {
                                    try process.run()
                                    // Erst die Pipe leeren, DANN auf Exit warten — sonst
                                    // Deadlock, wenn die mediainfo-Ausgabe den Pipe-Puffer füllt.
                                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                                    process.waitUntilExit()
                                    if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                                        session.addLog("--- MediaInfo Eigenschaften ---\n" + output, type: .dim)
                                        // Gilt in BEIDEN Modi: aac_at/CVBR wird von ffmpeg+mediainfo
                                        // immer als 'Constant' gelabelt (verifiziert), nicht nur beim
                                        // Stream-Copy. Der Audio-Stream bleibt dennoch Constrained VBR.
                                        session.addLog("Hinweis: MediaInfo labelt aac_at/CVBR fälschlicherweise als 'Bitrate-Modus: Constant'. Die Audiodaten sind dennoch durchgehend variables Apple CVBR.", type: .dim)
                                    }
                                } catch {
                                    // Startet mediainfo nicht (Binary entfernt/nicht ausführbar),
                                    // NICHT auf die Pipe warten: readDataToEndOfFile() bekäme nie
                                    // EOF (das Schreib-Ende bliebe offen) → Dauer-Deadlock. Die
                                    // Nachanalyse ist rein informativ, also einfach überspringen.
                                    session.logVerbose("MediaInfo-Nachanalyse übersprungen: \(error.localizedDescription)")
                                }
                            }
                            
                            // THEN PRINT SUCCESS INFO
                            session.addLog("✅ Datei erfolgreich erstellt!", type: .highlight)
                            session.addLog("Name: \(finalURL.lastPathComponent)", type: .info)
                            session.addLog("Pfad: \(finalURL.path)", type: .info)
                            session.addLog("Größe: \(session.formatFileSize(size))", type: .info)
                        } else {
                            session.addLog("❌ KRITISCHER FEHLER beim Erstellen von \(finalURL.lastPathComponent). Datei ist leer. Vorgang abgebrochen.", type: .highlight)
                            removeTempDir(tempDir)
                            overallSuccess = false
                            break
                        }
                    } catch {
                        session.addLog("✅ Datei erstellt, aber Dateigröße konnte nicht ermittelt werden.", type: .info)
                    }
                } else {
                    session.addLog("❌ KRITISCHER FEHLER beim Erstellen von \(finalURL.lastPathComponent). Vorgang abgebrochen.", type: .highlight)
                    removeTempDir(tempDir)
                    overallSuccess = false
                    break
                }
                removeTempDir(tempDir)
            }

            DispatchQueue.main.async {
                session.isConverting = false
                session.progress = 1.0
                session.lastConversionSucceeded = overallSuccess
                session.conversionStatus = overallSuccess ? "Erfolgreich abgeschlossen" : "Mit Fehlern beendet"
                session.addLog(overallSuccess ? "🏁 Alle Vorgänge beendet." : "🏁 Vorgang mit Fehlern beendet.", type: .highlight)
            }
        }
    }

    private static func runParallelTasks(group: [AudioFile], tempDir: URL, session: ConversionSession, progressWeight: Double,
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
            session.segmentProgress = [:]
            if !showIndividualPacmans {
                session.initSegmentProgress(index: 0, filename: "Audio-Dekodierung (WAV)")
            }
        }

        for (idx, file) in group.enumerated() {
            completionGroup.enter()
            groupQueue.async {
                semaphore.wait()
                
                if getIsCancelled() {
                    semaphore.signal()
                    completionGroup.leave()
                    return
                }
                
                let segmentURL = tempDir.appendingPathComponent("seg_\(idx).\(extensionStr)")
                let finalArgs = argsProvider(idx, file, segmentURL)
                
                if showIndividualPacmans {
                    DispatchQueue.main.async { session.initSegmentProgress(index: idx, filename: file.name) }
                }

                let process = Process()
                process.executableURL = ffmpegURL
                process.arguments = finalArgs
                
                registerProcess(process)
                defer { unregisterProcess(process) }
                
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
                                let p = currentSeconds / file.duration
                                if showIndividualPacmans {
                                    session.updateSegmentProgress(index: idx, progress: p)
                                } else {
                                    tracker.lock.lock()
                                    tracker.progresses[idx] = p
                                    let totalP = tracker.progresses.values.reduce(0, +) / Double(group.count)
                                    tracker.lock.unlock()
                                    DispatchQueue.main.async { session.updateSegmentProgress(index: 0, progress: totalP) }
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
                    if getIsCancelled() { process.terminate() }
                    process.waitUntilExit()
                    reader.readabilityHandler = nil
                    // Letzten, evtl. noch im Puffer liegenden stderr-Rest nachlesen,
                    // damit die Fehlermeldung vollständig ist.
                    let rest = reader.availableData
                    if !rest.isEmpty { stderrLock.lock(); stderrBuffer.append(rest); stderrLock.unlock() }
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
                            DispatchQueue.main.async { 
                                session.progress = (Double(finishedCount) / Double(group.count)) * progressWeight 
                                if showIndividualPacmans {
                                    session.updateSegmentProgress(index: idx, progress: 1.0)
                                } else if finishedCount == group.count {
                                    session.updateSegmentProgress(index: 0, progress: 1.0)
                                }
                            }
                            lock.unlock()
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
                    session.addLog("❌ Prozess-Fehler bei Segment \(idx+1): \(error.localizedDescription)", type: .highlight)
                }
                semaphore.signal()
                completionGroup.leave()
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

    private static func performSequentialConversion(session: ConversionSession, group: [AudioFile], tempDir: URL, finalURL: URL) -> Bool {
        let wavPaths = runParallelTasks(group: group, tempDir: tempDir, session: session, progressWeight: 0.2, extensionStr: "wav", showIndividualPacmans: false) { idx, file, url in
            return FFmpegWrapper.getArgsForStandardSlicing(idx: idx, file: file, url: url, session: session)
        }
        guard let validPaths = wavPaths else { return false }
        let listFile = tempDir.appendingPathComponent("audio_list.txt")
        let metaFile = tempDir.appendingPathComponent("chapters.txt")
        guard writeConcatAndChapters(validPaths: validPaths, group: group, listFile: listFile, metaFile: metaFile, session: session) else { return false }
        let coverInput = resolveCoverInputPath(session: session, tempDir: tempDir)
        var args = ["-nostdin", "-y", "-f", "concat", "-safe", "0", "-i", listFile.path, "-i", metaFile.path]
        if let coverInput = coverInput { args += ["-i", coverInput] }
        args += ["-c:a", "aac_at", "-aac_at_mode", "cvbr", "-b:a", session.settings.bitrate, "-ar", "\(session.settings.sampleRate)", "-ac", session.settings.isMono ? "1" : "2"]
        // album = Buchtitel: Hörbuch-Konvention, damit Player das Buch als ein Album gruppieren.
        args += ["-metadata", "title=\(session.title)", "-metadata", "album=\(session.title)", "-metadata", "artist=\(session.author)", "-metadata", "genre=\(session.genre)", "-map", "0:a", "-map_metadata", "1"]
        if coverInput != nil { args += ["-map", "2:0", "-c:v", "copy", "-disposition:v", "attached_pic"] }
        args.append(finalURL.path)
        return runFinalProcess(args: args, session: session, baseProgress: 0.2, logMessage: "🛠️ Starte komplette Apple CVBR Kodierung...", pacmanTitle: "Apple AAC Encoding")
    }

    private static func performParallelConversion(session: ConversionSession, group: [AudioFile], tempDir: URL, finalURL: URL) -> Bool {
        let aacPaths = runParallelTasks(group: group, tempDir: tempDir, session: session, progressWeight: 0.9, extensionStr: "m4a", showIndividualPacmans: true) { idx, file, url in
            return FFmpegWrapper.getArgsForParallelEncoding(idx: idx, file: file, url: url, session: session)
        }
        guard let validPaths = aacPaths else { return false }
        let listFile = tempDir.appendingPathComponent("audio_list.txt")
        let metaFile = tempDir.appendingPathComponent("chapters.txt")
        guard writeConcatAndChapters(validPaths: validPaths, group: group, listFile: listFile, metaFile: metaFile, session: session) else { return false }
        let coverInput = resolveCoverInputPath(session: session, tempDir: tempDir)
        var args = ["-nostdin", "-y", "-f", "concat", "-safe", "0", "-i", listFile.path, "-i", metaFile.path]
        if let coverInput = coverInput { args += ["-i", coverInput] }
        args += ["-c", "copy", "-map", "0:a", "-map_metadata", "1"]
        // album = Buchtitel: Hörbuch-Konvention, damit Player das Buch als ein Album gruppieren.
        args += ["-metadata", "title=\(session.title)", "-metadata", "album=\(session.title)", "-metadata", "artist=\(session.author)", "-metadata", "genre=\(session.genre)"]
        if coverInput != nil { args += ["-map", "2:0", "-c:v", "copy", "-disposition:v", "attached_pic"] }
        args.append(finalURL.path)
        return runFinalProcess(args: args, session: session, baseProgress: 0.9, logMessage: "🛠️ Finaler Stream-Copy & MP4-Muxing gestartet...", pacmanTitle: "Finaler Zusammenbau")
    }

    private static func runFinalProcess(args: [String], session: ConversionSession, baseProgress: Double, logMessage: String, pacmanTitle: String) -> Bool {
        DispatchQueue.main.async {
            session.segmentProgress = [:]
            session.initSegmentProgress(index: 0, filename: pacmanTitle)
        }
        if getIsCancelled() { return false }
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
        
        registerProcess(process)
        defer { unregisterProcess(process) }
        
        do {
            try process.run()
            let reader = pipe.fileHandleForReading
            
            reader.readabilityHandler = { fileHandle in
                let data = fileHandle.availableData
                if data.isEmpty { return }
                if let output = String(data: data, encoding: .utf8) {
                    if let timeString = extractTimeFromFFmpeg(output),
                       let currentSeconds = timeToSeconds(timeString) {
                        DispatchQueue.main.async {
                            let total = session.totalDuration
                            guard total > 0 else { return }
                            let p = currentSeconds / total
                            session.progress = baseProgress + (p * (1.0 - baseProgress))
                            session.updateSegmentProgress(index: 0, progress: p)
                        }
                    }
                }
            }
            
            process.waitUntilExit()
            reader.readabilityHandler = nil
            if process.terminationStatus == 0 {
                DispatchQueue.main.async { session.updateSegmentProgress(index: 0, progress: 1.0) }
                return true
            }
            session.addLog("❌ KRITISCHER FEHLER beim finalen Zusammenfügen. Exit-Code: \(process.terminationStatus)", type: .highlight)
            return false
        } catch {
            session.addLog("❌ KRITISCHER FEHLER: \(error.localizedDescription)", type: .highlight)
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

    static func splitAudioFilesIfNeeded(_ files: [AudioFile], maxDurationHours: Int?) -> [[AudioFile]] {
        guard let maxHours = maxDurationHours, maxHours > 0 else { return [files] } // KORREKTUR: [files] statt [L]
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


    public static func cancelConversion(session: ConversionSession) {
        setIsCancelled(true)
        
        // Alle aktiven ffmpeg-Prozesse (inkl. des Final-Prozesses, der ebenfalls
        // in activeProcesses registriert ist) beenden. Ein separater
        // currentProcess-Zeiger ist überflüssig und war nicht gelockt.
        registryLock.lock()
        for process in activeProcesses {
            if process.isRunning {
                process.terminate()
            }
        }
        activeProcesses.removeAll()
        // Aktive Temp-Verzeichnisse (große Zwischen-WAVs!) gleich mit aufräumen —
        // bei CLI-SIGINT beendet sich der Prozess sofort, der reguläre Cleanup in
        // convert() käme sonst nicht mehr dazu und es blieben GBs liegen.
        let tempDirs = activeTempDirs
        activeTempDirs.removeAll()
        registryLock.unlock()

        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }

        DispatchQueue.main.async {
            session.isConverting = false
            session.lastConversionSucceeded = false
            session.addLog("🛑 Vorgang durch Nutzer abgebrochen.", type: .info)
        }
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
                    if creationDate < oneDayAgo {
                        print("🧹 Bereinige altes temporäres Verzeichnis: \(url.path)")
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
    static func getArgsForStandardSlicing(idx: Int, file: AudioFile, url: URL, session: ConversionSession) -> [String] {
        // Zwischen-WAV direkt auf die Ziel-Abtastrate slicen statt hart auf 44100.
        // Sonst würde z.B. bei Ziel 48000 zweimal resampelt (Quelle→44100 beim
        // Slicen, 44100→48000 beim finalen Encode) — unnötiger Qualitätsverlust.
        // Ebenso auf die Ziel-KANALZAHL slicen (nicht hart Stereo): unkomprimiertes
        // WAV ist der Temp-Treiber (Standard-Modus hält ALLE Slices gleichzeitig),
        // und für ein Mono-Hörbuch (Default) halbiert Mono-Slicing den Temp-Bedarf.
        // Der finale `-ac`-Downmix bleibt identisch, nur eben schon beim Slicen.
        return ["-nostdin", "-y", "-ss", "\(file.startTime)", "-t", "\(file.duration)", "-i", file.url.path, "-vn", "-acodec", "pcm_s16le", "-ar", "\(session.settings.sampleRate)", "-ac", session.settings.isMono ? "1" : "2", url.path]
    }

    static func getArgsForParallelEncoding(idx: Int, file: AudioFile, url: URL, session: ConversionSession) -> [String] {
        return ["-nostdin", "-y", "-ss", "\(file.startTime)", "-t", "\(file.duration)", "-i", file.url.path, "-vn", "-c:a", "aac_at", "-aac_at_mode", "cvbr", "-b:a", session.settings.bitrate, "-ar", "\(session.settings.sampleRate)", "-ac", session.settings.isMono ? "1" : "2", url.path]
    }
}
