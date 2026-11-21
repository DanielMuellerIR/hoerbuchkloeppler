import Foundation

/// Unveränderlicher Laufzeit-Snapshot für den ffmpeg-Worker. Der Worker liest
/// dadurch nie nebenläufig aus dem Main-Actor-Modell `ConversionSession`.
struct ConversionJob: Sendable {
    let plan: ConversionPlan
    // Der Worker muss die Sperren bis zum letzten Commit beziehungsweise bis
    // zum vollständigen Abbruch halten. Die Eigenschaft wird nur zur Lebensdauer
    // genutzt; die Deskriptoren selbst bleiben im `OutputLeaseSet` gekapselt.
    let outputLeases: OutputLeaseSet
    let settings: AudioSettings
    let title: String
    let author: String
    let genre: String
    let narrator: String
    let series: String
    let volumeNumber: String
    let language: String
    let coverData: Data?
}

struct EncodingProgress: Sendable {
    let base: Double
    let weight: Double

    func map(_ fraction: Double) -> Double {
        FFmpegWrapper.mappedProgress(base: base, weight: weight, phaseProgress: fraction)
    }
}

struct ConversionPipeline: Sendable {
    let job: ConversionJob
    let session: ConversionSession
    let context: ConversionContext

    func start(
        totalDuration: TimeInterval,
        measureBookLoudness: (@Sendable () throws -> LoudnessMeasurement)?
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Die Sperren bleiben auch während der Abbruch- und Restbereinigung aktiv.
            defer { withExtendedLifetime(job.outputLeases) {} }
            let outputs = encodeBook(totalDuration: totalDuration, measureBookLoudness: measureBookLoudness)
            context.finishAfterCancellationCleanup { cancelled in
                context.cleanupResidualStagedOutputs()
                session.enqueueConversionFinished(
                    success: outputs.count == job.plan.groups.count,
                    cancelled: cancelled,
                    completedOutputs: outputs,
                    runID: context.id
                )
            }
        }
    }

    private func encodeBook(
        totalDuration: TimeInterval,
        measureBookLoudness: (@Sendable () throws -> LoudnessMeasurement)?
    ) -> [URL] {
        guard !context.isCancelled else { return [] }
        guard let ffmpeg = ToolLocator.binaryURL(name: "ffmpeg") else {
            session.enqueueLog(
                "ffmpeg wurde nicht gefunden (weder gebündelt noch im PATH/Homebrew/MacPorts). Bitte ./build.sh ausführen oder ffmpeg installieren.",
                type: .error,
                runID: context.id
            )
            return []
        }
        let encoder = SegmentEncoder(
            executableURL: ffmpeg,
            session: session,
            context: context,
            settings: job.settings,
            inputSnapshots: job.plan.inputSnapshots
        )
        guard let gain = LoudnessAnalyzer.gain(for: job, encoder: encoder, measure: measureBookLoudness) else {
            return []
        }

        var outputs: [URL] = []
        var completedDuration: TimeInterval = 0
        for (index, files) in job.plan.groups.enumerated() {
            let duration = files.reduce(0) { $0 + $1.duration }
            let progress = EncodingProgress(
                base: totalDuration > 0 ? completedDuration / totalDuration : 0,
                weight: totalDuration > 0 ? duration / totalDuration : 1
            )
            guard let output = convertGroup(
                index: index,
                files: files,
                encoder: encoder,
                gain: gain,
                duration: duration,
                progress: progress
            ) else { break }
            outputs.append(output)
            completedDuration += duration
        }
        return outputs
    }

    private func convertGroup(
        index: Int,
        files: [AudioFile],
        encoder: SegmentEncoder,
        gain: Double,
        duration: TimeInterval,
        progress: EncodingProgress
    ) -> URL? {
        guard !context.isCancelled else { return nil }
        let destination = job.plan.outputURLs[index]
        do {
            try ConversionPlanner.validateInputSnapshots(for: files, expected: job.plan.inputSnapshots)
        } catch {
            session.enqueueLog("\(error.localizedDescription)", type: .error, runID: context.id)
            return nil
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HB_Temp_\(UUID().uuidString)")
        do {
            try OwnedTemporaryDirectory.create(directory)
        } catch {
            session.enqueueLog(
                "Temporäres Arbeitsverzeichnis konnte nicht erstellt werden: \(error.localizedDescription)",
                type: .error,
                runID: context.id
            )
            return nil
        }
        context.registerTempDirectory(directory)
        defer { context.removeTempDirectory(directory) }

        guard let staging = prepareStaging(for: destination, at: index) else { return nil }
        let parallel = job.settings.useParallelEncoding
        let segmentWeight = progress.weight * (parallel ? 0.9 : 0.2)
        let segmentProgress = EncodingProgress(base: progress.base, weight: segmentWeight)
        let muxProgress = EncodingProgress(
            base: progress.base + segmentWeight,
            weight: progress.weight - segmentWeight
        )
        guard let segments = encoder.encode(
            files,
            in: directory,
            mode: parallel ? .encodeAAC(gainDB: gain) : .decodeWAV,
            progress: segmentProgress
        ), FFmpegMuxer.mux(
            segments,
            group: files,
            directory: directory,
            staging: staging,
            job: job,
            session: session,
            context: context,
            executableURL: encoder.executableURL,
            audioMode: parallel ? .streamCopy : .encodeAAC(settings: job.settings, gainDB: gain),
            progress: muxProgress,
            duration: duration
        ), !context.isCancelled, let size = FileSystemEntry.nonemptyFileSize(staging.url) else {
            context.discardStagedOutput(staging.url)
            if !context.isCancelled {
                session.enqueueLog(
                    "KRITISCHER FEHLER beim Erstellen von \(destination.lastPathComponent). Vorgang abgebrochen.",
                    type: .error,
                    runID: context.id
                )
            }
            return nil
        }

        // MediaInfo untersucht die fertige Staging-Datei vor der atomaren Übernahme.
        logStagedMediaInfo(staging.url)
        guard commit(staging, at: index) else { return nil }

        session.enqueueLog("Datei erfolgreich erstellt!", type: .highlight, runID: context.id)
        session.enqueueLog("Name: \(destination.lastPathComponent)", type: .info, runID: context.id)
        session.enqueueLog("Pfad: \(destination.path)", type: .info, runID: context.id)
        session.enqueueLog("Größe: \(FFmpegWrapper.formatFileSize(size))", type: .info, runID: context.id)
        return destination
    }

    private func prepareStaging(for destination: URL, at index: Int) -> StagingOutputHandle? {
        do {
            try ConversionPlanner.validateOutputDirectorySnapshot(
                for: destination,
                expected: job.plan.outputDirectorySnapshots[index]
            )
        } catch {
            session.enqueueLog("\(error.localizedDescription)", type: .error, runID: context.id)
            return nil
        }

        OutputCleanup.removeOrphans(for: destination) { message in
            session.enqueueLog(message, type: .highlight, runID: context.id)
        }
        do {
            let staging = try OutputStaging.createProtectedOutput(for: destination)
            context.registerStagedOutput(staging.url, ownership: staging.ownership)
            return staging
        } catch {
            session.enqueueLog(
                "Temporäre Ausgabedatei konnte nicht exklusiv angelegt werden: \(error.localizedDescription)",
                type: .error,
                runID: context.id
            )
            return nil
        }
    }

    private func logStagedMediaInfo(_ url: URL) {
        guard let executable = ToolLocator.binaryURL(name: "mediainfo"),
              !context.isCancelled else { return }
        let result = ProcessRunner.capture(
            executableURL: executable,
            arguments: [url.path],
            context: context,
            timeout: 10
        )
        switch result {
        case .completed(let status, let data) where status == 0:
            guard let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty, !context.isCancelled else { return }
            session.enqueueLog("--- MediaInfo Eigenschaften ---\n" + output, type: .dim, runID: context.id)
            session.enqueueLog(
                "Hinweis: MediaInfo labelt aac_at/CVBR fälschlicherweise als 'Bitrate-Modus: Constant'. Die Audiodaten sind dennoch durchgehend variables Apple CVBR.",
                type: .dim,
                runID: context.id
            )
        case .cancelled:
            break
        case .timedOut:
            session.enqueueVerboseLog(
                "MediaInfo-Nachanalyse nach 10 Sekunden beendet; die fertige Ausgabe wird trotzdem übernommen.",
                runID: context.id
            )
        case .completed(let status, _):
            session.enqueueVerboseLog(
                "MediaInfo-Nachanalyse mit Exit-Code \(status) übersprungen; die fertige Ausgabe wird trotzdem übernommen.",
                runID: context.id
            )
        case .failed(let reason):
            session.enqueueVerboseLog("MediaInfo-Nachanalyse übersprungen: \(reason)", runID: context.id)
        }
    }

    private func commit(_ staging: StagingOutputHandle, at index: Int) -> Bool {
        let destination = job.plan.outputURLs[index]
        let expectedDestination = job.plan.outputSnapshots[index]
        do {
            var displacedOutputRemoved = true
            let committed = try context.performCommit(isLastOutput: index == job.plan.groups.count - 1) {
                displacedOutputRemoved = try OutputCommit.publish(
                    staging.url,
                    to: destination,
                    expectedDestination: expectedDestination,
                    expectedDestinationDirectory: job.plan.outputDirectorySnapshots[index],
                    expectedStagingOwnership: staging.ownership
                )
            }
            guard committed else {
                context.discardStagedOutput(staging.url)
                return false
            }
            if displacedOutputRemoved {
                context.completeStagedOutput(staging.url)
            } else {
                if case .existing(let identity) = expectedDestination {
                    context.registerDisplacedOutput(
                        staging.url,
                        expectedIdentity: identity,
                        stagingOwnership: staging.ownership
                    )
                }
                session.enqueueLog(
                    "Die frühere Ausgabe bleibt vorläufig als versteckte Sicherungsdatei liegen: \(staging.url.path)",
                    type: .warning,
                    runID: context.id
                )
            }
            OutputStaging.clearOwnerMarker(destination)
            return true
        } catch {
            context.handleCommitFailure(error, stagedURL: staging.url)
            session.enqueueLog(
                "Ausgabe konnte nicht atomar übernommen werden: \(error.localizedDescription)",
                type: .error,
                runID: context.id
            )
            return false
        }
    }
}
