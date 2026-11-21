import Foundation

enum FFmpegMuxer {
    private static func writeConcatAndChapters(
        segments: [URL],
        group: [AudioFile],
        listFile: URL,
        metaFile: URL,
        session: ConversionSession,
        runID: UUID
    ) -> Bool {
        let metaContent = FFMetadata.encodeChapters(group: group)
        do {
            try FFmpegWrapper.writeConcatList(segments, to: listFile)
            try metaContent.write(to: metaFile, atomically: true, encoding: .utf8)
            return true
        } catch {
            session.enqueueLog(
                "KRITISCHER FEHLER: Steuerdateien konnten nicht geschrieben werden: \(error.localizedDescription)",
                type: .error,
                runID: runID
            )
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
        audioMode: MuxAudioMode,
        job: ConversionJob
    ) -> [String] {
        var arguments = [
            "-nostdin", "-y", "-f", "concat", "-safe", "0", "-i", listFile.path,
            "-i", metaFile.path
        ]
        // Parallelmodus: Die fertig kodierten Segmente werden per concat nur
        // noch kopiert (`-c:a copy`). Ohne `-copyts` setzt ffmpeg die Zeitstempel
        // je Segment neu auf und die Kapitelmarken aus der FFMETADATA-Datei
        // verschieben sich gegen den Ton. Abnahme der Kapitelstarts beider Modi:
        // tests/verify_audio_transitions.py.
        arguments += audioMode.timestampArguments
        if let coverInput { arguments += ["-i", coverInput] }
        arguments += audioMode.codecArguments
        arguments += [
            "-map", "0:a", "-map_metadata", "1",
            "-metadata", "title=\(job.title)",
            "-metadata", "album=\(job.title)",
            "-metadata", "artist=\(job.author)",
            "-metadata", "genre=\(job.genre)",
            "-metadata", "composer=\(job.narrator)",
            "-metadata", "grouping=\(job.series)",
            "-metadata", "disc=\(job.volumeNumber)",
            "-metadata", "language=\(job.language)",
            "-metadata:s:a:0", "language=\(job.language)"
        ]
        if coverInput != nil {
            arguments += ["-map", "2:0", "-c:v", "copy", "-disposition:v", "attached_pic"]
        }
        // Der MP4-Muxer leitet das Format sonst aus der Dateiendung ab. Der
        // Produktionspfad schreibt aber auf einen Dateideskriptor, deshalb muss
        // das Format ausdrücklich dabeistehen.
        arguments += ["-f", "ipod", "/dev/fd/0"]
        return arguments
    }

    static func mux(
        _ segments: [URL],
        group: [AudioFile],
        directory: URL,
        staging: StagingOutputHandle,
        job: ConversionJob,
        session: ConversionSession,
        context: ConversionContext,
        executableURL: URL,
        audioMode: MuxAudioMode,
        progress: EncodingProgress,
        duration: TimeInterval
    ) -> Bool {
        let listFile = directory.appendingPathComponent("audio_list.txt")
        let metaFile = directory.appendingPathComponent("chapters.txt")
        guard writeConcatAndChapters(
            segments: segments,
            group: group,
            listFile: listFile,
            metaFile: metaFile,
            session: session,
            runID: context.id
        ) else { return false }

        let coverInput = resolveCoverInputPath(
            job: job,
            session: session,
            tempDir: directory,
            runID: context.id
        )
        let args = finalMuxArguments(
            listFile: listFile,
            metaFile: metaFile,
            coverInput: coverInput,
            audioMode: audioMode,
            job: job
        )
        let logMessage: String
        let progressTitle: String
        let phase: ConversionPhase
        switch audioMode {
        case .encodeAAC:
            logMessage = "Starte komplette Apple CVBR Kodierung..."
            progressTitle = "Apple AAC Encoding"
            phase = .encoding
        case .streamCopy:
            logMessage = "Finaler Stream-Copy & MP4-Muxing gestartet..."
            progressTitle = "Finaler Zusammenbau"
            phase = .muxing
        }

        return run(
            args: args,
            session: session,
            context: context,
            progressBase: progress.base,
            progressWeight: progress.weight,
            phaseDuration: duration,
            logMessage: logMessage,
            pacmanTitle: progressTitle,
            phase: phase,
            staging: staging,
            executableURL: executableURL
        )
    }

    static func run(
        args: [String],
        session: ConversionSession,
        context: ConversionContext,
        progressBase: Double,
        progressWeight: Double,
        phaseDuration: TimeInterval,
        logMessage: String,
        pacmanTitle: String,
        phase: ConversionPhase = .encoding,
        staging: StagingOutputHandle? = nil,
        beforeProcessStart: (() -> Void)? = nil,
        executableURL: URL
    ) -> Bool {
        session.enqueueSegmentReset(title: pacmanTitle, phase: phase, runID: context.id)
        if context.isCancelled { return false }
        session.enqueueLog(logMessage, type: .highlight, runID: context.id)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = args
        if let staging {
            // Foundation erhält den offenen Staging-Deskriptor als stdin und
            // hält ihn beim Spawn als Dateideskriptor 0 offen. ffmpeg schreibt
            // nach /dev/fd/0 und folgt dadurch keinem austauschbaren Pfad.
            process.standardInput = staging.processInputHandle()
        }
        let pipe = Pipe()
        process.standardError = pipe
        session.enqueueVerboseLog(
            "Führe Final-Prozess aus: ffmpeg \(args.joined(separator: " "))",
            runID: context.id
        )

        defer { context.unregister(process) }

        do {
            if let staging, !staging.stillOwnsProtectedOutput() {
                session.enqueueLog(
                    "Geschützte temporäre Ausgabe wurde vor dem ffmpeg-Start ausgetauscht.",
                    type: .error,
                    runID: context.id
                )
                return false
            }
            beforeProcessStart?()
            guard try context.run(process) else { return false }
            let outputReader = ProcessPipeReader(handle: pipe.fileHandleForReading)
            try? pipe.fileHandleForWriting.close()
            outputReader.start(state: FFmpegProgressParser()) { parser, data in
                guard let currentSeconds = parser.consume(data), phaseDuration > 0 else { return }
                let progress = min(1, max(0, currentSeconds / phaseDuration))
                session.enqueueProgress(
                    FFmpegWrapper.mappedProgress(base: progressBase, weight: progressWeight, phaseProgress: progress),
                    segmentIndex: 0,
                    segmentProgress: progress,
                    runID: context.id
                )
            }

            process.waitUntilExit()
            let hadBackgroundProcesses = ProcessTerminator
                .terminateRemainingOwnedGroup(process)
            let stderrData = outputReader.waitUntilEOF(timeout: 0.25)
            if context.isCancelled { return false }
            if hadBackgroundProcesses {
                session.enqueueLog(
                    "KRITISCHER FEHLER: Werkzeug meldete Exit, ließ aber Hintergrundprozesse zurück. Die Ausgabe wird nicht übernommen.",
                    type: .error,
                    runID: context.id
                )
                return false
            }
            if outputReader.joinTimedOut || outputReader.failedToReadOutput {
                session.enqueueLog(
                    "KRITISCHER FEHLER: Werkzeugausgabe blieb unvollständig. Die Ausgabe wird nicht übernommen.",
                    type: .error,
                    runID: context.id
                )
                return false
            }
            if process.terminationStatus == 0 {
                session.enqueueProgress(
                    FFmpegWrapper.mappedProgress(
                        base: progressBase,
                        weight: progressWeight,
                        phaseProgress: 1
                    ),
                    segmentIndex: 0,
                    segmentProgress: 1,
                    runID: context.id
                )
                return true
            }
            let details = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = details.map { $0.isEmpty ? "" : "\n\($0)" } ?? ""
            session.enqueueLog(
                "KRITISCHER FEHLER beim finalen Zusammenfügen. "
                + "Exit-Code: \(process.terminationStatus)\(suffix)",
                type: .error,
                runID: context.id
            )
            return false
        } catch {
            if !context.isCancelled {
                session.enqueueLog(
                    "KRITISCHER FEHLER: \(error.localizedDescription)",
                    type: .error,
                    runID: context.id
                )
            }
            return false
        }
    }

    /// Schreibt den vor Workerstart aufgenommenen Cover-Snapshot in `tempDir`
    /// und liefert seinen Pfad für ffmpeg. Damit liest der Mux weder eine später
    /// ausgetauschte manuelle Bilddatei noch veränderlichen Session-Zustand.
    private static func resolveCoverInputPath(
        job: ConversionJob,
        session: ConversionSession,
        tempDir: URL,
        runID: UUID
    ) -> String? {
        if let data = job.coverData {
            let coverURL = tempDir.appendingPathComponent("cover.img")
            do {
                try data.write(to: coverURL)
                return coverURL.path
            } catch {
                session.enqueueLog(
                    "Eingebettetes Cover konnte nicht zwischengespeichert werden — Output ohne Cover.",
                    type: .warning,
                    runID: runID
                )
                return nil
            }
        }
        return nil
    }
}
