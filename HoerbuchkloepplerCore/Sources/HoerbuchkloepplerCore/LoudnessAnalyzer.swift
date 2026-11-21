import Foundation

enum LoudnessAnalyzer {
    static func gain(
        for job: ConversionJob,
        encoder: SegmentEncoder,
        measure: (@Sendable () throws -> LoudnessMeasurement)?
    ) -> Double? {
        guard job.settings.analyzeLoudness || job.settings.normalizeLoudness else { return 0 }

        let session = encoder.session
        let context = encoder.context
        do {
            let measurement = try measure?() ?? measureBook(plan: job.plan, encoder: encoder)
            let gain = job.settings.normalizeLoudness ? measurement.gainDB : 0
            let gainDescription = job.settings.normalizeLoudness
                ? "; gemeinsamer Gain: \(gain) dB"
                : "; Analyse ohne Pegeländerung"
            session.enqueueLog(measurement.description + gainDescription, type: .info, runID: context.id)
            return context.isCancelled ? nil : gain
        } catch {
            guard !context.isCancelled else { return nil }
            if job.settings.normalizeLoudness {
                session.enqueueLog(
                    "Lautheitsanalyse fehlgeschlagen: \(error.localizedDescription)",
                    type: .highlight,
                    runID: context.id
                )
                return nil
            }

            // Der Dekodierpass kann den Start weiterer Prozesse gesperrt haben.
            // Nach reiner Informationsanalyse darf die Kodierung trotzdem starten.
            context.clearSegmentFailure()
            session.enqueueLog(
                "Lautheitsanalyse fehlgeschlagen, die Konvertierung läuft ohne Messwert weiter: \(error.localizedDescription)",
                type: .highlight,
                runID: context.id
            )
            return 0
        }
    }

    private static func measureBook(plan: ConversionPlan, encoder: SegmentEncoder) throws -> LoudnessMeasurement {
        let session = encoder.session
        let context = encoder.context
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HB_Temp_\(UUID().uuidString)")
        try OwnedTemporaryDirectory.create(directory)
        context.registerTempDirectory(directory)
        defer { context.removeTempDirectory(directory) }

        session.enqueueLog(
            "Lautheitsanalyse: zusätzlicher vollständiger Dekodier- und Analysepass für das gesamte Buch; temporärer WAV-Bestand.",
            type: .info,
            runID: context.id
        )
        let files = plan.groups.flatMap { $0 }
        guard let segments = encoder.encode(
            files,
            in: directory,
            mode: .decodeWAV,
            progress: EncodingProgress(base: 0, weight: 0)
        ) else {
            throw LoudnessError.bookDecodingFailed
        }
        session.enqueueSegmentReset(title: "Buchlautheit messen", phase: .measuringLoudness, runID: context.id)
        let list = directory.appendingPathComponent("analysis.txt")
        try FFmpegWrapper.writeConcatList(segments, to: list)

        let process = Process()
        process.executableURL = encoder.executableURL
        process.arguments = [
            "-nostdin", "-hide_banner", "-nostats", "-f", "concat", "-safe", "0", "-i", list.path,
            "-af", "loudnorm=I=-18:TP=-1:LRA=50:print_format=json", "-f", "null", "-"
        ]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        let reader = ProcessPipeReader(handle: pipe.fileHandleForReading)
        guard try context.run(process) else { throw CancellationError() }
        defer { context.unregister(process) }
        try? pipe.fileHandleForWriting.close()
        reader.start()
        process.waitUntilExit()
        let background = ProcessTerminator.terminateRemainingOwnedGroup(process)
        let data = reader.waitUntilEOF(timeout: 0.25)
        if context.isCancelled { throw CancellationError() }
        guard !reader.joinTimedOut, !reader.failedToReadOutput else {
            throw LoudnessError.incompleteToolOutput
        }
        guard process.terminationStatus == 0, !background else {
            throw LoudnessError.analysisFailed(diagnostic: String(decoding: data, as: UTF8.self))
        }
        try ConversionPlanner.validateInputSnapshots(for: files, expected: plan.inputSnapshots)
        return try LoudnessMeasurement.parse(data)
    }
}
