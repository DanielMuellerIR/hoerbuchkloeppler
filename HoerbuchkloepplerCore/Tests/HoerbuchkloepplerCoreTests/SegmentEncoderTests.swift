import Foundation
import Testing
@testable import HoerbuchkloepplerCore

@Suite("Begrenzte Segmentverarbeitung", .enabled(if: ProcessInfo.processInfo.activeProcessorCount >= 2))
@MainActor
struct SegmentEncoderTests {
    @Test("Mit zwei Workern wird die Eingabereihenfolge trotz früher fertiger Segmente erhalten")
    func limitsWorkersAndReturnsInputOrder() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (encoder, files) = try makeEncoder(in: directory, behavior: """
            if index == 0:
                mark("started-0")
                await_file("finished-2")
            elif index == 1:
                await_file("started-0")
                time.sleep(0.2)
            elif index == 2 and not (root / "seg_1.wav").exists():
                sys.exit("Dritter Worker vor Abschluss eines der ersten Segmente gestartet")
            output.write_text(str(index))
            with (root / "finish-order").open("a") as log:
                print(index, file=log)
            mark(f"finished-{index}")
            """)

        let paths = try #require(await encode(files, using: encoder, in: directory))
        #expect(paths.map(\.lastPathComponent) == ["seg_0.wav", "seg_1.wav", "seg_2.wav"])
        let completionOrder = try String(
            contentsOf: directory.appendingPathComponent("finish-order"),
            encoding: .utf8
        ).split(separator: "\n")
        #expect(completionOrder == ["1", "2", "0"])
    }

    @Test("Ein fataler Segmentfehler beendet aktive Prozesse und stoppt weitere Starts")
    func fatalSegmentTerminatesOtherWorker() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (encoder, files) = try makeEncoder(in: directory, behavior: """
            import signal

            def stopped(_signal, _frame):
                mark("terminated-0")
                sys.exit(0)

            if index == 0:
                signal.signal(signal.SIGTERM, stopped)
                mark("started-0")
                await_file("never-released")
            elif index == 1:
                await_file("started-0")
                sys.exit(23)
            else:
                mark("started-2")
            """)

        #expect(await encode(files, using: encoder, in: directory) == nil)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("terminated-0").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("started-2").path))
        #expect(!encoder.context.canRunSegments)
        #expect(!encoder.context.isCancelled)
    }

    @Test("Verwaiste Kindprozesse sperren weitere Segmente vor Beginn ihrer Bereinigung", arguments: [0, 23])
    func leftoverProcessesStopStartsBeforeCleanup(exitStatus: Int) async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (encoder, files) = try makeEncoder(in: directory, behavior: """
            import os, signal

            def release_other_worker(_signal, _frame):
                mark("descendant-got-term")

            if index == 0:
                mark("started-0")
                await_file("descendant-got-term")
                output.write_text("0")
            elif index == 1:
                await_file("started-0")
                if os.fork() == 0:
                    signal.signal(signal.SIGTERM, release_other_worker)
                    mark("descendant-ready")
                    await_file("started-2")
                    sys.exit(0)
                await_file("descendant-ready")
                print("Ursache aus dem Werkzeug", file=sys.stderr)
                sys.exit(\(exitStatus))
            else:
                mark("started-2")
                output.write_text("2")
            """)

        #expect(await encode(files, using: encoder, in: directory) == nil)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("descendant-got-term").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("started-2").path))

        let loggedFailure = { encoder.session.eventLogs.first { $0.message.contains("Hintergrundprozesse") } }
        for _ in 0..<100 where loggedFailure() == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let failure = try #require(loggedFailure())
        #expect(failure.message.contains("Segment 2"))
        if exitStatus != 0 {
            #expect(failure.message.contains("Exit-Code \(exitStatus)"))
            #expect(failure.message.contains("Ursache aus dem Werkzeug"))
        }
        #expect(!encoder.context.isCancelled)
    }

    private func makeEncoder(in directory: URL, behavior: String) throws -> (SegmentEncoder, [AudioFile]) {
        let script = """
            #!/usr/bin/python3
            import pathlib, sys, time

            output = pathlib.Path(sys.argv[-1])
            root = output.parent
            index = int(output.stem.split("_")[1])

            def mark(name):
                (root / name).touch()

            def await_file(name):
                deadline = time.monotonic() + 5
                while not (root / name).exists():
                    if time.monotonic() >= deadline:
                        sys.exit(f"Timeout: {name}")
                    time.sleep(0.01)

            """
        let executable = directory.appendingPathComponent("ffmpeg-fixture")
        try (script + "\n" + behavior + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let input = directory.appendingPathComponent("input.wav")
        try Data([0]).write(to: input)
        let files = (0..<3).map {
            AudioFile(url: input, startTime: TimeInterval($0), duration: 1, chapterTitle: "Kapitel \($0)")
        }
        let plan = FFmpegWrapper.makeConversionPlan(
            files: files,
            outputURL: directory.appendingPathComponent("book.m4b"),
            maxDurationHours: nil
        )
        let settings = AudioSettings(workerLimit: 2)
        let session = ConversionSession(settings: settings)
        let encoder = SegmentEncoder(
            executableURL: executable,
            session: session,
            context: session.beginConversionRun(),
            settings: settings,
            inputSnapshots: plan.inputSnapshots
        )
        return (encoder, files)
    }

    private func encode(_ files: [AudioFile], using encoder: SegmentEncoder, in directory: URL) async -> [URL]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: encoder.encode(
                    files,
                    in: directory,
                    mode: .decodeWAV,
                    progress: EncodingProgress(base: 0, weight: 1)
                ))
            }
        }
    }
}
