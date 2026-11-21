import Foundation
import os

final class ParallelProgressTracker: Sendable {
    private let progressByIndex = OSAllocatedUnfairLock(initialState: [Int: Double]())
    private let durations: [Double]
    private let totalDuration: Double

    init(durations: [Double]) {
        self.durations = durations
        totalDuration = durations.reduce(0, +)
    }

    /// Der Fortschritt eines langen Kapitels trägt mehr zum Buchfortschritt bei.
    func update(index: Int, progress: Double) -> Double {
        guard totalDuration > 0 else { return 0 }
        return progressByIndex.withLock { progresses in
            progresses[index] = max(progresses[index] ?? 0, min(1, max(0, progress)))
            return progresses.reduce(0.0) { sum, item in
                sum + item.value * durations[item.key] / totalDuration
            }
        }
    }
}

/// Verteilt die Segmentindizes und trägt fertige Dateien an ihrer Eingabeposition ein.
private final class SegmentBatch: Sendable {
    private struct State {
        var nextIndex = 0
        var completedCount = 0
        var outputs: [URL?]
    }

    private let state: OSAllocatedUnfairLock<State>

    init(count: Int) {
        state = OSAllocatedUnfairLock(initialState: State(outputs: Array(repeating: nil, count: count)))
    }

    func claimIndex() -> Int? {
        state.withLock {
            guard $0.nextIndex < $0.outputs.count else { return nil }
            let index = $0.nextIndex
            $0.nextIndex += 1
            return index
        }
    }

    func record(_ output: URL, at index: Int) -> Bool {
        state.withLock {
            $0.outputs[index] = output
            $0.completedCount += 1
            return $0.completedCount == $0.outputs.count
        }
    }

    func orderedOutputs() -> [URL]? {
        state.withLock {
            guard $0.completedCount == $0.outputs.count else { return nil }
            return $0.outputs.compactMap { $0 }
        }
    }
}

struct SegmentEncoder: Sendable {
    enum Mode: Sendable {
        case decodeWAV
        case encodeAAC(gainDB: Double)

        var fileExtension: String {
            switch self {
            case .decodeWAV: "wav"
            case .encodeAAC: "m4a"
            }
        }

        var showsIndividualProgress: Bool {
            if case .encodeAAC = self { return true }
            return false
        }

        func arguments(for file: AudioFile, output: URL, settings: AudioSettings) -> [String] {
            switch self {
            case .decodeWAV:
                FFmpegWrapper.getArgsForStandardSlicing(file: file, url: output, settings: settings)
            case .encodeAAC(let gainDB):
                FFmpegWrapper.getArgsForParallelEncoding(file: file, url: output, settings: settings, gainDB: gainDB)
            }
        }
    }

    private enum Outcome {
        case completed(URL)
        case stopped
        case failed(String)
    }

    let executableURL: URL
    let session: ConversionSession
    let context: ConversionContext
    let settings: AudioSettings
    let inputSnapshots: [String: OutputDestinationSnapshot]

    /// Der Konvertierungsworker wartet auf einer Dispatch-Queue. Auch die
    /// blockierenden Prozess-Waits der Segmentworker laufen auf Dispatch-Queues.
    func encode(
        _ files: [AudioFile],
        in directory: URL,
        mode: Mode,
        progress: EncodingProgress
    ) -> [URL]? {
        let workerCount = min(settings.effectiveWorkerLimit, files.count)
        let workers = DispatchQueue(label: "com.hoerbuchkloeppler.encoding.segments", attributes: .concurrent)
        let completion = DispatchGroup()
        let batch = SegmentBatch(count: files.count)
        let tracker = ParallelProgressTracker(durations: files.map(\.duration))
        let individualProgress = mode.showsIndividualProgress

        session.enqueueSegmentReset(
            title: individualProgress ? nil : "Audio-Dekodierung (WAV)",
            phase: individualProgress ? .encoding : .decoding,
            runID: context.id
        )

        for _ in 0..<workerCount {
            workers.async(group: completion) {
                while context.canRunSegments, let index = batch.claimIndex() {
                    let file = files[index]
                    let output = directory.appendingPathComponent("seg_\(index).\(mode.fileExtension)")
                    let outcome = encodeSegment(
                        file,
                        at: index,
                        to: output,
                        mode: mode
                    ) { fraction in
                        let total = tracker.update(index: index, progress: fraction)
                        session.enqueueProgress(
                            progress.map(total),
                            segmentIndex: individualProgress ? index : 0,
                            segmentProgress: individualProgress ? fraction : total,
                            runID: context.id
                        )
                    }
                    switch outcome {
                    case .completed(let output):
                        let total = tracker.update(index: index, progress: 1)
                        let allCompleted = batch.record(output, at: index)
                        let showCompletion = individualProgress || allCompleted
                        session.enqueueProgress(
                            progress.map(allCompleted ? 1 : total),
                            segmentIndex: showCompletion ? (individualProgress ? index : 0) : nil,
                            segmentProgress: showCompletion ? 1 : nil,
                            runID: context.id
                        )
                    case .stopped:
                        return
                    case .failed(let message):
                        context.failSegments {
                            session.enqueueLog(message, type: .error, runID: context.id)
                        }
                        return
                    }
                }
            }
        }
        completion.wait()
        guard context.canRunSegments else { return nil }
        return batch.orderedOutputs()
    }

    private func encodeSegment(
        _ file: AudioFile,
        at index: Int,
        to output: URL,
        mode: Mode,
        onProgress: @escaping @Sendable (Double) -> Void
    ) -> Outcome {
        guard context.canRunSegments else { return .stopped }
        do {
            try ConversionPlanner.validateInputSnapshots(for: [file], expected: inputSnapshots)
        } catch {
            return .failed("\(error.localizedDescription)")
        }

        if mode.showsIndividualProgress {
            session.enqueueSegmentInitialization(index: index, filename: file.name, runID: context.id)
        }

        let number = index + 1
        let arguments = mode.arguments(for: file, output: output, settings: settings)
        session.enqueueVerboseLog(
            "Starte Segment \(number): ffmpeg \(arguments.joined(separator: " "))",
            runID: context.id
        )

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        let reader = ProcessPipeReader(handle: pipe.fileHandleForReading)

        do {
            guard try context.run(process) else { return .stopped }
        } catch {
            return .failed("Prozess-Fehler bei Segment \(number): \(error.localizedDescription)")
        }
        defer { context.unregister(process) }
        try? pipe.fileHandleForWriting.close()
        reader.start(state: FFmpegProgressParser()) { parser, data in
            guard let seconds = parser.consume(data), file.duration > 0 else { return }
            onProgress(min(1, max(0, seconds / file.duration)))
        }

        process.waitUntilExit()
        let status = process.terminationStatus
        let hadBackgroundProcesses = ProcessTerminator.hasRemainingOwnedGroup(process)
        // Beide Befunde sperren weitere Starts vor TERM/KILL und dem Pipe-Join.
        // Der Prozess bleibt für den Abbruch oder die erste Fehlerbereinigung registriert.
        let reportsExitFailure = (status != 0 || hadBackgroundProcesses) && context.failSegments()
        let stderr = reader.waitUntilEOF(timeout: 0.25)
        if reportsExitFailure {
            let descendants = "Segment \(number) ließ nach dem Werkzeug-Exit Hintergrundprozesse zurück; der Batch wird verworfen."
            let message: String
            if status == 0 {
                message = descendants
            } else {
                let diagnostic = String(data: stderr, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let details = diagnostic.isEmpty ? "Unbekannter FFmpeg-Fehler" : diagnostic
                let explanation = hadBackgroundProcesses ? "\n\(descendants)" : ""
                message = "Segment \(number) fehlgeschlagen (Exit-Code \(status)):\n\(details)\(explanation)"
            }
            session.enqueueLog(message, type: .error, runID: context.id)
            return .stopped
        }
        // Erst nach dem Reader-Join darf die Anzeige in die nächste Phase wechseln.
        guard context.canRunSegments else { return .stopped }
        if reader.joinTimedOut || reader.failedToReadOutput {
            return .failed("Segment \(number) lieferte keine vollständige Werkzeugausgabe; der Batch wird verworfen.")
        }

        do {
            // ffmpeg öffnet die Quelle selbst. Ein Austausch während des Lesens
            // darf auch bei Exit 0 kein gültiges Segment liefern.
            try ConversionPlanner.validateInputSnapshots(for: [file], expected: inputSnapshots)
        } catch {
            return .failed("\(error.localizedDescription)")
        }
        guard FileSystemEntry.nonemptyFileSize(output) != nil else {
            return .failed("Zieldatei Segment \(number) ist leer oder fehlt.")
        }
        return .completed(output)
    }
}
