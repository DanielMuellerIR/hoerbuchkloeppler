import ArgumentParser
import Combine
import Darwin
import Foundation
import HoerbuchkloepplerCore

@MainActor
struct CLIExecution {
    private let options: CLIOptions
    private let output: CLIOutput
    private let interrupts = InterruptState()
    // Die CLI nutzt reproduzierbare Defaults unabhängig von der App-Konfiguration.
    private let session = ConversionSession(settings: AudioSettings())

    init(options: CLIOptions) {
        self.options = options
        output = CLIOutput(format: options.format)
    }

    func run() async throws {
        let sourceURL = try resolveSource()
        // Der sichtbare Pfad bleibt für den Dateinamen erhalten. Der physische
        // Ordner wird sofort gebunden, falls der übergebene Link später wechselt.
        let resolvedSource = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        if !options.inspect { FFmpegWrapper.cleanupOldTempDirectories() }
        session.logSink = output.log
        let signalSources = interrupts.install(for: session)
        defer { signalSources.forEach { $0.cancel() } }

        var failure: (any Error)?
        var preparingConversion = false
        var reportedInspection = false
        do {
            try await loadInput(sourceURL, resolvedSource: resolvedSource)
            try applyOverrides()
            try throwIfInterrupted()
            let plan = try makePlan(sourceURL: sourceURL)
            if options.project != nil {
                try await prepareProject { try await session.verifyProjectSources() }
            }
            if options.inspect {
                try await reportInspection(plan)
                reportedInspection = true
                if !session.projectSourceIssues.isEmpty { throw ExitCode.failure }
            } else {
                guard session.projectSourceIssues.isEmpty else {
                    throw reportedFailure("Projektquellen fehlen oder wurden verändert.")
                }
                preparingConversion = true
                try await convert(plan)
            }
        } catch {
            failure = error
        }

        // Ein akzeptiertes Signal hat Vorrang vor einem gleichzeitig
        // eintreffenden Fehler. Der Handler kann seinen Exit-Code erst
        // festlegen, nachdem der Core den Abbruch angenommen hat.
        let signal = interrupts.finishExecution()
        announceInterrupt()
        if output.isJSON, !reportedInspection {
            let event: RunReport.Event = signal != nil ? .cancelled : (failure != nil ? .failed : .finished)
            let state = session.runState
            let fallbackPhase: ConversionPhase = preparingConversion ? .preparing : .input
            try output.emitJSON(RunReport(
                event: event,
                phase: state.machinePhase == .idle ? fallbackPhase : state.machinePhase,
                progress: state.progress,
                outputs: state.completedOutputs
            ))
        }
        if let signal { throw ExitCode(128 + signal) }
        if let failure { throw failure }
    }

    private func resolveSource() throws -> URL {
        if let path = options.project ?? options.files.first {
            return URL(fileURLWithPath: path)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: options.folderPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            if output.isJSON { try output.emitJSON(RunReport(event: .failed, phase: .input, progress: 0)) }
            throw reportedFailure("Fehler: Der Pfad \(options.folderPath) existiert nicht oder ist kein Ordner.")
        }
        return URL(fileURLWithPath: options.folderPath)
    }

    private func loadInput(_ sourceURL: URL, resolvedSource: URL) async throws {
        if let workers = options.importWorkers { session.settings.importWorkerLimit = workers }
        session.beginPreparation()
        try throwIfInterrupted()
        let analyzeArtwork = options.cover == nil && !options.noCover
        if options.project != nil {
            try await prepareProject { try await session.openProjectAsync(from: sourceURL) }
            // Die Projektübernahme beendet den Import-Kontext und ersetzt die
            // Einstellungen. Die Quellenprüfung braucht einen neuen Kontext.
            session.beginPreparation()
            if let workers = options.importWorkers { session.settings.importWorkerLimit = workers }
        } else if !options.files.isEmpty {
            if !analyzeArtwork { session.removeCover() }
            await session.importFiles(
                options.files.map { URL(fileURLWithPath: $0) },
                analyzeArtwork: analyzeArtwork,
                usingExistingPreparation: true
            )
        } else {
            await session.prepareFolder(resolvedSource, analyzeArtwork: analyzeArtwork)
        }
        try throwIfInterrupted()
        if !session.lastImportFailures.isEmpty {
            writeStandardError("Fehler: Der Ordnerimport wurde vollständig verworfen:")
            for failure in session.lastImportFailures {
                writeStandardError("  \(failure.sourceDescription): \(failure.message)")
            }
            throw ExitCode.failure
        }
        guard !session.audioFiles.isEmpty else {
            throw reportedFailure("Fehler: Keine gültigen Audiodateien im Ordner gefunden.")
        }
    }

    private func prepareProject(_ operation: @escaping @MainActor @Sendable () async throws -> Void) async throws {
        var failure: (any Error)?
        await session.runPreparationTask {
            do { try await operation() }
            catch { failure = error }
        }
        try throwIfInterrupted()
        if let failure { throw failure }
    }

    private func applyOverrides() throws {
        if options.analyzeLoudness { session.settings.analyzeLoudness = true }
        if options.normalizeLoudness { session.settings.normalizeLoudness = true }
        if let narrator = options.narrator { session.narrator = narrator }
        if let series = options.series { session.series = series }
        if let volumeNumber = options.volumeNumber { session.volumeNumber = volumeNumber }
        if let language = options.language { session.language = language }
        if let workers = options.workers { session.settings.workerLimit = workers }
        if let mode = options.mode { session.settings.useParallelEncoding = mode == .parallel }
        if let bitrate = options.bitrate { session.settings.bitrate = bitrate }
        if let samplerate = options.samplerate { session.settings.sampleRate = samplerate }
        if let maxDuration = options.maxDuration { session.settings.maxDurationHours = maxDuration > 0 ? maxDuration : nil }
        if options.mono { session.settings.isMono = true }
        else if options.stereo { session.settings.isMono = false }
        if options.verbose { session.settings.isVerbose = true }

        if let title = options.title { session.title = title }
        if let author = options.author { session.author = author }
        if let genre = options.genre { session.genre = genre }
        if options.noCover {
            session.removeCover()
        } else if let cover = options.cover {
            try selectCover(cover)
        }
    }

    private func selectCover(_ path: String) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw reportedFailure("❌ Cover-Datei konnte nicht geprüft werden: \(path)")
        }
        let limit = CoverArtwork.maximumByteCount
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes <= limit else {
            throw reportedFailure(
                "❌ Cover muss eine reguläre Bilddatei mit höchstens \(limit / (1024 * 1024)) MiB sein: \(path)"
            )
        }
        guard session.selectCover(url: url) else {
            throw reportedFailure("❌ Cover-Datei ist nicht als Bild lesbar: \(path)")
        }
    }

    private func makePlan(sourceURL: URL) throws -> ConversionPlan {
        let fallback = options.project != nil || !options.files.isEmpty
            ? sourceURL.deletingPathExtension().lastPathComponent
            : sourceURL.lastPathComponent
        let title = CLIDestination.sanitizeFilename(session.title.isEmpty ? fallback : session.title)
        let target = try CLIDestination.resolve(
            option: options.output, sourceURL: sourceURL, title: title, createDirectories: !options.inspect
        )
        let plan = FFmpegWrapper.makeConversionPlan(
            files: session.audioFiles, outputURL: target, maxDurationHours: session.settings.maxDurationHours
        )
        // Der nummerierte Suffix eines Split-Laufs gehört zum fertigen Namen.
        if let invalid = plan.outputURLs.first(where: { $0.lastPathComponent.utf8.count > Int(NAME_MAX) }) {
            throw reportedFailure("❌ Ausgabe-Dateiname ist länger als \(NAME_MAX) UTF-8-Bytes: \(invalid.lastPathComponent)")
        }
        return plan
    }

    private func reportInspection(_ plan: ConversionPlan) async throws {
        if output.isJSON {
            try output.emitJSON(await InspectionReport(session: session, outputs: plan.outputURLs))
        } else {
            output.text("\(session.audioFiles.count) Kapitel, \(session.totalDuration) Sekunden")
            for url in plan.outputURLs { output.text(url.path) }
            for issue in session.projectSourceIssues { output.text("\(issue.reason): \(issue.path)") }
        }
    }

    private func convert(_ plan: ConversionPlan) async throws {
        if output.isJSON {
            try output.emitJSON(RunReport(event: .started, phase: .preparing, progress: 0, outputs: plan.outputURLs))
        }
        output.text("Starte Konvertierung...")
        output.text(plan.outputURLs.count == 1 ? "Zieldatei:" : "Zieldateien:")
        for url in plan.outputURLs { output.text("  \(url.path)") }
        try confirmOverwrite(plan)

        guard interrupts.beginConversion() else {
            try throwIfInterrupted()
            throw ExitCode.failure
        }
        if case .rejected(let message) = FFmpegWrapper.startVerifiedConversion(session: session, plan: plan) {
            throw reportedFailure("❌ Konvertierung konnte nicht gestartet werden: \(message)")
        }
        // Ein Signal zwischen Phasenwechsel und dem Core-Start findet erst
        // hier den neuen Kontext, dessen Arbeit es abbrechen soll.
        if interrupts.wasReceived { _ = FFmpegWrapper.cancelConversion(session: session) }

        if options.verbose, let image = session.coverImage {
            output.text("\n--- Cover ASCII Art ---")
            output.text(TerminalArtwork.asciiCover(from: image, width: 40))
            output.text("-----------------------\n")
        }

        try await observeConversion(outputs: plan.outputURLs)
        try throwIfInterrupted()
        try reportConversionResult(plan)
    }

    private func confirmOverwrite(_ plan: ConversionPlan) throws {
        let existing = plan.outputURLsRequiringOverwriteConfirmation
        guard !existing.isEmpty else { return }
        let names = existing.map(\.lastPathComponent).joined(separator: ", ")
        if options.force {
            output.text("⚠️ Vorhandene Zieldatei(en) werden überschrieben (--force): \(names)")
            return
        }
        // Ohne sichtbares Terminal oder interaktive Eingabe hat die Frage
        // möglicherweise niemanden, der sie beantworten kann.
        guard isatty(FileHandle.standardInput.fileDescriptor) != 0,
              output.renderer.isInteractive else {
            throw reportedFailure("❌ Zieldatei(en) existieren bereits: \(names). Zum Überschreiben --force verwenden.")
        }
        output.text("⚠️ Diese Zieldatei(en) existieren bereits: \(names)")
        output.prompt("Möchten Sie die Dateien überschreiben? (j/N): ")
        if let answer = readLine(unlessInterrupted: interrupts),
           answer.lowercased() == "j" || answer.lowercased() == "y" {
            output.text("Datei wird überschrieben...")
            return
        }
        try throwIfInterrupted()
        writeStandardError("Vorgang abgebrochen.")
        throw ExitCode(2)
    }

    private func observeConversion(outputs: [URL]) async throws {
        // Der Publisher sendet beim Setzen. Ein Signal reicht, um danach auf
        // dem Main Actor den vollständigen und aktuellsten Stand zu lesen.
        let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let subscription = session.$runState.sink { _ in continuation.yield() }
        var visibleState = session.runState
        var reportedProgress: Double?
        var reportedPhase: ConversionPhase?
        // Nur im sichtbaren Terminal bewegt sich die Figur zwischen Updates.
        // Abschluss und Datenberichte hängen ausschließlich am Publisher.
        let animation: Task<Void, Never>? = output.animatesProgress ? Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
                output.drawProgress(visibleState)
            }
        } : nil
        defer {
            animation?.cancel()
            subscription.cancel()
            continuation.finish()
            output.renderer.clearBlock()
        }
        for await _ in updates {
            announceInterrupt()
            visibleState = session.runState
            if output.isJSON {
                if reportedProgress != visibleState.progress || reportedPhase != visibleState.machinePhase {
                    try output.emitJSON(RunReport(
                        event: .progress,
                        phase: visibleState.machinePhase,
                        progress: visibleState.progress,
                        outputs: outputs
                    ))
                    reportedProgress = visibleState.progress
                    reportedPhase = visibleState.machinePhase
                }
            } else {
                output.drawProgress(visibleState)
            }
            if visibleState.succeeded != nil { break }
        }
    }

    private func reportConversionResult(_ plan: ConversionPlan) throws {
        if session.lastConversionSucceeded == true {
            output.text(plan.outputURLs.count == 1 ? "🎉 Vorgang beendet. Datei:" : "🎉 Vorgang beendet. Dateien:")
            for url in plan.outputURLs { output.text("  \(url.path)") }
            return
        }
        let completed = session.completedOutputURLs
        if completed.isEmpty {
            writeStandardError("❌ Vorgang fehlgeschlagen. Es wurde keine gültige Datei erzeugt.")
        } else {
            writeStandardError("❌ Vorgang unvollständig. Erfolgreich erzeugte Datei(en):")
            for url in completed { writeStandardError("  \(url.path)") }
        }
        throw ExitCode.failure
    }

    private func throwIfInterrupted() throws {
        guard interrupts.wasReceived, let exit = interrupts.waitForExitCode() else { return }
        announceInterrupt()
        throw exit
    }

    private func announceInterrupt() {
        guard let signal = interrupts.takeUnannouncedSignal() else { return }
        let name = signal == SIGTERM ? "SIGTERM" : "SIGINT"
        output.log("⚠️ \(name) empfangen. Lauf wird geordnet abgebrochen …")
    }
}
