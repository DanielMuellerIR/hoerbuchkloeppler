import Foundation
import AVFoundation
import Darwin

enum ChapterExtractionResult: Sendable {
    case files([AudioFile])
    case failed(AudioImportFailure.Reason)
    case cancelled
}

private enum ChapterMetadataResult: Sendable {
    case chapters([FFMetadata.Chapter])
    case fallback(String)
    case failed(AudioImportFailure.Reason)
    case cancelled
}

private final class AudioAnalysisCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let process: Process

    init(process: Process) { self.process = process }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
        ProcessTerminator.requestTermination(process)
    }
}

private enum AudioAnalysisExecutor {
    // Die Import-Pipeline begrenzt die Zahl gleichzeitig laufender Analysen.
    // Eine serielle Queue würde auch unabhängige Quellen hinter einem hängenden
    // Werkzeug aufstauen. Keine dieser blockierenden Arbeiten gehört in einen Task.
    private static let queue = DispatchQueue(
        label: "com.hoerbuchkloeppler.chapter-analysis",
        qos: .utility,
        attributes: .concurrent
    )

    static func perform<Result: Sendable>(
        _ operation: @escaping @Sendable () -> Result
    ) async -> Result {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: operation()) }
        }
    }
}

extension AudioFile {
    /// Selbst eine beschädigte Datei darf die Kapitelanalyse nicht mit einer
    /// beliebig großen ffmetadata-Ausgabe im Speicher wachsen lassen. Acht MiB
    /// reichen auch bei sehr vielen Kapiteln um Größenordnungen aus.
    static let maximumFFMetadataByteCount = 8 * 1024 * 1024
    static let chapterExtractionTimeout: TimeInterval = 30

    /// Liest Cover als unveränderte Bildpakete durch eine begrenzte Pipe. Die
    /// AVMetadataItem-Daten würden erst nach vollständigem Laden prüfbar sein.
    public static func extractEmbeddedArtwork(from url: URL) async -> Data? {
        await extractEmbeddedArtwork(from: url, candidateCount: 64)
    }

    static func extractEmbeddedArtwork(
        from url: URL,
        candidateCount: Int,
        onRequest: @Sendable () -> Void = {}
    ) async -> Data? {
        guard candidateCount > 0, !Task.isCancelled,
              let executable = ToolLocator.binaryURL(name: "ffmpeg") else { return nil }
        let extractionStart = DispatchTime.now().uptimeNanoseconds
        for index in 0..<min(64, candidateCount) {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - extractionStart) / 1_000_000_000
            let remainingTimeout = 15 - elapsed
            guard remainingTimeout > 0, !Task.isCancelled else { return nil }
            let process = Process()
            process.executableURL = executable
            process.arguments = [
                "-nostdin", "-v", "quiet", "-max_alloc", String(CoverArtwork.maximumByteCount),
                "-i", url.path, "-map", "0:v:disp:attached_pic:\(index)",
                "-c", "copy", "-frames:v", "1", "-f", "image2pipe", "pipe:1"
            ]
            let cancellation = AudioAnalysisCancellation(process: process)
            onRequest()
            let result: (data: Data?, streamFound: Bool) = await withTaskCancellationHandler {
                await AudioAnalysisExecutor.perform {
                    guard !cancellation.isCancelled else { return (nil, false) }
                    let pipe = Pipe()
                    defer {
                        try? pipe.fileHandleForReading.close()
                        try? pipe.fileHandleForWriting.close()
                    }
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = pipe
                    process.standardError = FileHandle.nullDevice
                    do {
                        try process.run()
                        ProcessTerminator.recordOwnedProcessGroup(process)
                        defer { ProcessTerminator.forgetOwnedProcessGroup(process) }
                        try? pipe.fileHandleForWriting.close()
                        let start = DispatchTime.now().uptimeNanoseconds
                        let output = readAnalysisOutput(
                            from: pipe.fileHandleForReading,
                            maximumByteCount: CoverArtwork.maximumByteCount,
                            timeout: remainingTimeout,
                            shouldCancel: { cancellation.isCancelled }
                        ) { ProcessTerminator.terminateAndWait([process]) }
                        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
                        if !waitForProcessExit(process, timeout: max(0, remainingTimeout - elapsed)) {
                            ProcessTerminator.terminateAndWait([process])
                        }
                        if !process.isRunning { process.waitUntilExit() }
                        ProcessTerminator.terminateRemainingOwnedGroup(process)
                        guard !cancellation.isCancelled, !process.isRunning,
                              process.terminationStatus == 0,
                              !output.exceededLimit, !output.timedOut, !output.readFailed else { return (nil, false) }
                        return (validatedEmbeddedArtworkData(output.data), true)
                    } catch { return (nil, false) }
                }
            } onCancel: { cancellation.cancel() }
            guard !Task.isCancelled else { return nil }
            if let data = result.data { return data }
            if !result.streamFound { break }
        }
        return nil
    }

    static func isArtworkItem(_ item: AVMetadataItem) -> Bool {
        if let key = item.commonKey?.rawValue, key == "artwork" || key == "cover" { return true }
        guard let key = item.key else { return false }
        let name = String(describing: key).lowercased()
        return name.contains("artwork") || name.contains("cover")
    }

    /// Übernimmt für eingebettete Cover dieselbe Größen- und Decode-Grenze wie
    /// der Dateipfad für ein manuell gewähltes Cover. Ein kaputter erster
    /// Artwork-Tag darf die Suche nach einem späteren gültigen Tag nicht beenden.
    static func validatedEmbeddedArtworkData(_ data: Data?) -> Data? {
        guard let data, CoverArtwork.thumbnail(from: data, maximumDimension: 32) != nil else { return nil }
        return data
    }

    /// Analysiert m4b/mp4 Dateien mit dem **gebündelten** `ffmpeg` und extrahiert
    /// die Kapitelstruktur. Nutzt absichtlich kein `ffprobe` — das ist NICHT
    /// mitgeliefert und fehlt auf Maschinen ohne Homebrew, wodurch m4b-Kapitel
    /// in der verteilten App verloren gingen. `ffmpeg -f ffmetadata -` schreibt
    /// die Metadaten (inkl. `[CHAPTER]`-Blöcke) nach stdout.
    public static func extractChapters(from file: FoundFile) async -> [AudioFile]? {
        guard file.isChapterContainer else { return nil }
        switch await extractChaptersControlled(from: file) {
        case .files(let files): return files
        case .failed: return []
        case .cancelled: return []
        }
    }

    /// Variante für `ConversionSession`: Sie registriert den gestarteten
    /// ffmpeg-Prozess beim laufbezogenen Vorbereitungs-Context und leitet
    /// Meldungen in das gemeinsame Session-Log statt direkt auf stdout.
    static func extractChaptersControlled(
        from file: FoundFile,
        knownFile: AudioFile? = nil,
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        configureProcess: @escaping @Sendable (Process) -> Void = { _ in },
        runProcess: @escaping @Sendable (Process) throws -> Bool = { process in
            try process.run()
            ProcessTerminator.recordOwnedProcessGroup(process)
            return true
        },
        unregisterProcess: @escaping @Sendable (Process) -> Void = {
            ProcessTerminator.forgetOwnedProcessGroup($0)
        },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> ChapterExtractionResult {
        func fallbackFile() async -> AudioFile {
            if let knownFile { return knownFile }
            return await AudioFile(foundFile: file)
        }
        let url = file.readURL
        let visibleURL = file.source
        guard file.isChapterContainer else { return .files([]) }
        guard !shouldCancel(), !Task.isCancelled else { return .cancelled }

        guard let ffmpegURL = ToolLocator.binaryURL(name: "ffmpeg") else {
            log("ffmpeg wurde nicht gefunden. Kapitel-Extraktion übersprungen.")
            return .files([await fallbackFile()])
        }

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = ["-nostdin", "-v", "quiet", "-i", url.path, "-f", "ffmetadata", "-"]
        let pipe = Pipe()

        let cancellation = AudioAnalysisCancellation(process: process)
        return await withTaskCancellationHandler {
            let metadata: ChapterMetadataResult = await AudioAnalysisExecutor.perform {
                defer {
                    try? pipe.fileHandleForWriting.close()
                    try? pipe.fileHandleForReading.close()
                }
                do {
                    guard !shouldCancel(), !cancellation.isCancelled else { return .cancelled }
                    // Der Test kann hier einen kontrollierten Ersatzprozess einsetzen. Die
                    // Produktionsaufrufer lassen die vorbereitete ffmpeg-Konfiguration
                    // unverändert.
                    configureProcess(process)
                    process.standardOutput = pipe
                    // stderr getrennt verwerfen, damit es weder die Metadaten-Ausgabe stört
                    // noch in einer ungelesenen Pipe den Kindprozess blockieren kann.
                    process.standardError = FileHandle.nullDevice
                    // `-nostdin` deckt nur echtes ffmpeg ab. Ein über `$PATH` aufgelöstes
                    // Wrapper-Skript erbte sonst den stdin der App beziehungsweise das
                    // Terminal der CLI und könnte dort auf Eingabe warten.
                    process.standardInput = FileHandle.nullDevice
                    guard !shouldCancel(), !cancellation.isCancelled else { return .cancelled }
                    guard try runProcess(process) else { return .cancelled }
                    defer { unregisterProcess(process) }
                    try? pipe.fileHandleForWriting.close()
                    // Cancel kann genau zwischen dem letzten Check und `run()` liegen.
                    // Der Context hat den damals noch nicht laufenden Process dann nicht
                    // beendet; nach dem Start deshalb nochmals prüfen.
                    if shouldCancel() || cancellation.isCancelled {
                        ProcessTerminator.requestTermination(process)
                    }
                    // Erst die Pipe leeren, DANN auf Exit warten — sonst Deadlock, wenn
                    // die Kapitelliste den Pipe-Puffer (~64 KB) füllt. Die Datenmenge
                    // bleibt begrenzt; bei Überschreitung beendet der Leser ffmpeg und
                    // kehrt ohne weitere Datenübernahme zurück.
                    let extractionStart = DispatchTime.now().uptimeNanoseconds
                    let output = readAnalysisOutput(
                        from: pipe.fileHandleForReading,
                        timeout: chapterExtractionTimeout,
                        shouldCancel: { shouldCancel() || cancellation.isCancelled }
                    ) {
                        // Synchron beenden: Danach darf `waitUntilExit()` nicht an
                        // einem hängenden direkten Kindprozess festbleiben.
                        ProcessTerminator.terminateAndWait([process])
                    }
                    let extractionElapsed = TimeInterval(
                        DispatchTime.now().uptimeNanoseconds - extractionStart
                    ) / 1_000_000_000
                    let processExited = waitForProcessExit(
                        process,
                        timeout: shouldCancel() || cancellation.isCancelled
                            ? 0 : max(0, chapterExtractionTimeout - extractionElapsed)
                    )
                    if !processExited {
                        ProcessTerminator.terminateAndWait([process])
                    }
                    // Ein Prozess im nicht unterbrechbaren Kernel-Wait — etwa auf
                    // einem abgerissenen Netz-Mount — überlebt auch SIGKILL. Ein
                    // unbedingtes `waitUntilExit()` machte die Frist hier wertlos.
                    if !process.isRunning { process.waitUntilExit() }
                    // Nach dem Exit des direkten Prozesses darf in seiner besessenen
                    // Gruppe kein Nachkomme weiterlaufen; danach vergisst das `defer`
                    // die Gruppe und der spätere Abbruchpfad fände ihn nicht mehr.
                    ProcessTerminator.terminateRemainingOwnedGroup(process)
                    guard !shouldCancel(), !cancellation.isCancelled else { return .cancelled }
                    guard !output.timedOut, processExited else {
                        log("Kapitelanalyse für \(visibleURL.lastPathComponent) nach \(Int(chapterExtractionTimeout)) Sekunden abgebrochen. Datei wird übersprungen.")
                        return .failed(.chapterAnalysisTimedOut)
                    }
                    guard !output.readFailed else {
                        return .fallback("Kapitelmetadaten aus \(visibleURL.lastPathComponent) konnten nicht vollständig gelesen werden. Nutze die Datei als ein Kapitel.")
                    }
                    guard !output.exceededLimit else {
                        return .fallback("Kapitelmetadaten in \(visibleURL.lastPathComponent) überschreiten 8 MiB. Nutze die Datei als ein Kapitel.")
                    }
                    guard process.terminationStatus == 0 else {
                        return .fallback("ffmpeg konnte Kapitel aus \(visibleURL.lastPathComponent) nicht vollständig lesen. Nutze die Datei als ein Kapitel.")
                    }

                    guard let text = String(data: output.data, encoding: .utf8) else {
                        return .fallback("FFMETADATA von \(visibleURL.lastPathComponent) nicht lesbar. Nutze die Datei als ein Kapitel.")
                    }
                    let chapters = FFMetadata.decodeChapters(text)
                    guard !chapters.isEmpty else {
                        return .fallback("Keine Kapitel in \(visibleURL.lastPathComponent) gefunden. Nutze die Datei als ein Kapitel.")
                    }

                    return .chapters(chapters)
                } catch {
                    if shouldCancel() || cancellation.isCancelled { return .cancelled }
                    return .fallback("Kapitel aus \(visibleURL.lastPathComponent) konnten nicht gelesen werden: \(error.localizedDescription)")
                }
            }
            guard !shouldCancel(), !Task.isCancelled else { return .cancelled }
            let parsedChapters: [FFMetadata.Chapter]
            switch metadata {
            case .chapters(let chapters): parsedChapters = chapters
            case .fallback(let message):
                log(message)
                let fallback = await fallbackFile()
                guard !shouldCancel(), !Task.isCancelled else { return .cancelled }
                return .files([fallback])
            case .failed(let reason): return .failed(reason)
            case .cancelled: return .cancelled
            }
            let totalDuration: Double
            if let knownFile {
                totalDuration = knownFile.duration
            } else {
                let loadedDuration = try? await AVURLAsset(url: url).load(.duration)
                totalDuration = sanitizeDuration(loadedDuration.map(CMTimeGetSeconds) ?? 0)
            }
            guard !shouldCancel(), !Task.isCancelled else { return .cancelled }
            let resolvedChapters: [AudioFile]? = await AudioAnalysisExecutor.perform {
                guard !shouldCancel(), !cancellation.isCancelled else { return nil }
                guard let chapters = FFMetadata.normalizedChapters(
                    parsedChapters, totalDuration: totalDuration
                ) else { return nil }

                var audioFiles: [AudioFile] = []
                for (index, ch) in chapters.enumerated() {
                    let title = ch.title.isEmpty ? "Kapitel \(index + 1)" : ch.title
                    // AudioFile.init klemmt Dauer/startTime auf endlich und >= 0.
                    audioFiles.append(AudioFile(
                        foundFile: file,
                        startTime: ch.start,
                        duration: ch.end - ch.start,
                        chapterTitle: title
                    ))
                }
                guard !shouldCancel(), !cancellation.isCancelled else { return nil }
                return audioFiles
            }
            guard !shouldCancel(), !Task.isCancelled else { return .cancelled }
            guard let resolvedChapters else {
                log("Unvollständige Kapitelzeiten in \(visibleURL.lastPathComponent). Nutze die Datei als ein Kapitel.")
                let fallback = await fallbackFile()
                guard !shouldCancel(), !Task.isCancelled else { return .cancelled }
                return .files([fallback])
            }
            log("\(resolvedChapters.count) Kapitel aus \(visibleURL.lastPathComponent) extrahiert.")
            return .files(resolvedChapters)
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Wartet höchstens die verbleibende Kapitelanalyse-Frist auf den Prozess.
    /// EOF allein bedeutet nicht, dass ein fehlerhaftes Ersatzprogramm beendet ist.
    static func waitForProcessExit(_ process: Process, timeout: TimeInterval) -> Bool {
        // Eine nichtendliche Frist bedeutet hier ausdrücklich „gar nicht warten“;
        // die Kapitelanalyse deckelt zusätzlich bei einer Stunde.
        let boundedTimeout = timeout.isFinite ? min(max(0, timeout), 3_600) : 0
        return ProcessTerminator.wait(upTo: boundedTimeout) { process.isRunning }
    }

    /// Liest eine Analyse-Pipe bis zu einer festen Obergrenze und Frist.
    /// `poll` hält die Frist auch dann ein, wenn weder Daten noch EOF kommen.
    /// Beim ersten Grenzfehler beendet `onAbort` den direkten Kindprozess; der
    /// Leser kehrt danach sofort zurück und wartet nicht auf vererbte Pipe-Enden.
    static func readAnalysisOutput(
        from handle: FileHandle,
        maximumByteCount: Int = maximumFFMetadataByteCount,
        timeout: TimeInterval = chapterExtractionTimeout,
        shouldCancel: () -> Bool = { false },
        onAbort: () -> Void = {}
    ) -> (data: Data, exceededLimit: Bool, timedOut: Bool, readFailed: Bool) {
        let limit = max(0, maximumByteCount)
        let boundedTimeout = timeout.isFinite ? min(max(0, timeout), 3_600) : chapterExtractionTimeout
        let deadline = ProcessDeadline(seconds: boundedTimeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if shouldCancel() {
                onAbort()
                return (data, false, false, true)
            }
            let wait = deadline.nextPollMilliseconds
            guard wait > 0 else {
                onAbort()
                return (data, false, true, false)
            }
            let count: Int
            switch ProcessPipeRead.poll(
                descriptor: handle.fileDescriptor,
                timeoutMilliseconds: wait,
                buffer: &buffer
            ) {
            case .retry: continue
            case .endOfFile: return (data, false, false, false)
            case .failed:
                onAbort()
                return (data, false, false, true)
            case .bytes(let byteCount): count = byteCount
            }
            guard count <= limit - data.count else {
                onAbort()
                return (data, true, false, false)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
