import Foundation
import Testing
@testable import HoerbuchkloepplerCore
import Darwin

@Suite("FFmpegWrapper – serieller Pipe-Leser")
struct ProcessPipeReaderTests {
    @Test("Fehlerhaftes Pipe-Ende gilt nicht als EOF")
    func distinguishesReadFailureFromEOF() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        let reader = ProcessPipeReader(handle: pipe.fileHandleForWriting)
        reader.start()
        #expect(reader.waitUntilEOF(timeout: 1).isEmpty)
        #expect(!reader.joinTimedOut)
        #expect(reader.failedToReadOutput)
    }

    @Test("Ein nie gestarteter Reader wird ohne offene Group freigegeben")
    func unstartedReaderIsReleased() {
        weak var releasedReader: ProcessPipeReader?
        do {
            let reader = ProcessPipeReader(handle: Pipe().fileHandleForReading)
            releasedReader = reader
        }
        #expect(releasedReader == nil)
    }

    @Test("waitUntilEOF wartet auf einen noch laufenden Callback")
    func waitsForCallbackJoin() throws {
        let pipe = Pipe()
        let reader = ProcessPipeReader(handle: pipe.fileHandleForReading)
        let callbackStarted = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let waitFinished = DispatchSemaphore(value: 0)

        reader.start { _ in
            callbackStarted.signal()
            releaseCallback.wait()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("stderr".utf8))
        try pipe.fileHandleForWriting.close()
        #expect(callbackStarted.wait(timeout: .now() + 1) == .success)

        Thread.detachNewThread {
            _ = reader.waitUntilEOF()
            waitFinished.signal()
        }
        let premature = waitFinished.wait(timeout: .now() + 0.05)
        releaseCallback.signal()
        #expect(premature == .timedOut)
        #expect(waitFinished.wait(timeout: .now() + 1) == .success)
    }

    @Test("Zeitwerte funktionieren über jede Chunk-Grenze und der neueste gewinnt")
    func parsesSplitAndLatestProgress() {
        let bytes = Data("frame=1 time=00:00:01.23 speed=1x".utf8)
        for split in 1..<bytes.count {
            var parser = FFmpegProgressParser()
            _ = parser.consume(Data(bytes[..<split]))
            #expect(parser.consume(Data(bytes[split...])) == 1.23)
        }

        var parser = FFmpegProgressParser()
        let newest = parser.consume(
            Data("time=00:00:01.00\rtime=00:00:02.50\r".utf8)
        )
        #expect(newest == 2.5)
    }

    @Test("Begrenzter Prozess eskaliert und Exit ungleich null bleibt sichtbar")
    func capturedProcessHonorsTimeoutAndStatus() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hanging = directory.appendingPathComponent("hanging")
        let failing = directory.appendingPathComponent("failing")
        // Schlafen statt rechnen: Der Prozess ignoriert SIGTERM weiterhin und
        // endet erst durch SIGKILL, sättigt dabei aber keinen Kern gegen die
        // parallel laufende Suite.
        try writeExecutable(
            hanging,
            "#!/bin/sh\ntrap '' TERM\nwhile :; do /bin/sleep 0.05; done\n"
        )
        try writeExecutable(failing, "#!/bin/sh\nprintf 'diagnose'\nexit 3\n")

        let start = Date()
        let timed = FFmpegWrapper.runCapturedProcess(
            executableURL: hanging,
            arguments: [],
            timeout: 0.05
        )
        guard case .timedOut = timed else {
            Issue.record("Hängender Prozess lieferte nicht .timedOut")
            return
        }
        #expect(Date().timeIntervalSince(start) < 2)

        let failed = FFmpegWrapper.runCapturedProcess(
            executableURL: failing,
            arguments: [],
            // Dieser Teil prüft Exit-Code und Ausgabe, nicht eine knappe
            // Zeitgrenze. Im parallelen Gesamtlauf kann selbst der kurze
            // Prozess unter Last länger als eine Sekunde bis zum Exit brauchen.
            timeout: 5
        )
        guard case .completed(let status, let output) = failed else {
            Issue.record("Beendeter Prozess lieferte kein Ergebnis")
            return
        }
        #expect(status == 3)
        #expect(String(data: output, encoding: .utf8) == "diagnose")
    }

    @Test("Ein Kind mit geerbtem stdout blockiert den Pipe-Join nicht")
    func inheritedPipeDescriptorDoesNotHang() throws {
        let script = """
        import subprocess, sys
        child = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            stdout=sys.stdout,
            stderr=sys.stderr,
        )
        print(child.pid, flush=True)
        """
        let start = Date()
        let result = FFmpegWrapper.runCapturedProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script],
            timeout: 2
        )
        guard case .completed(let status, let output) = result,
              let text = String(data: output, encoding: .utf8),
              let childPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            Issue.record("Helferprozess lieferte PID und Exit-Status nicht")
            return
        }
        #expect(status == 0)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(Darwin.kill(childPID, 0) == -1 && errno == ESRCH)
    }
}

@Suite("FFmpegWrapper – Prozessgruppen-Besitz")
struct ProcessGroupOwnershipTests {
    @Test("Abbruch beendet Nachkommen auch nach Ende des direkten Prozesses")
    func cancellationWaitsForDescendantsAfterLeaderExit() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let childPIDFile = directory.appendingPathComponent("child.pid")
        let script = """
        import os, subprocess, sys, time
        child = subprocess.Popen(["/bin/sleep", "30"])
        with open(sys.argv[1], "w", encoding="utf-8") as handle:
            handle.write(str(child.pid))
            handle.flush()
            os.fsync(handle.fileno())
        time.sleep(0.2)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, childPIDFile.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let context = ConversionContext()

        #expect(try context.run(process))
        process.waitUntilExit()
        let childPID = try #require(
            pid_t(String(contentsOf: childPIDFile, encoding: .utf8))
        )
        defer {
            if Darwin.kill(childPID, 0) == 0 {
                _ = Darwin.kill(childPID, SIGKILL)
            }
            context.unregister(process)
        }
        #expect(!process.isRunning)
        #expect(Darwin.kill(childPID, 0) == 0)

        #expect(context.cancel())
        let cleanupFinished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            context.finishAfterCancellationCleanup { _ in }
            cleanupFinished.signal()
        }
        #expect(cleanupFinished.wait(timeout: .now() + 5) == .success)

        let childExitDeadline = Date().addingTimeInterval(2)
        while Darwin.kill(childPID, 0) == 0, Date() < childExitDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(Darwin.kill(childPID, 0) == -1 && errno == ESRCH)
    }

    @Test("Task-Abbruch beendet den laufenden Kapitelextraktionsprozess")
    func chapterExtractionTaskCancellationTerminatesProcess() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("chapter.pid")
        let slowTool = directory.appendingPathComponent("chapter-tool")
        try writeExecutable(slowTool, """
        #!/bin/sh
        printf '%s' "$$" > "$1"
        trap 'exit 0' TERM INT
        while :; do /bin/sleep 1; done
        """)
        let source = directory.appendingPathComponent("Buch.m4b")
        let found = FoundFile(source: source, resolved: source)

        let extraction = Task {
            await AudioFile.extractChaptersControlled(
                from: found,
                configureProcess: { process in
                    process.executableURL = slowTool
                    process.arguments = [pidFile.path]
                }
            )
        }
        let startDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: pidFile.path),
              Date() < startDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let processPID = try #require(
            pid_t(String(contentsOf: pidFile, encoding: .utf8))
        )
        defer {
            if Darwin.kill(processPID, 0) == 0 {
                _ = Darwin.kill(processPID, SIGKILL)
            }
        }

        extraction.cancel()
        let result = await extraction.value
        guard case .cancelled = result else {
            Issue.record("Kapitelextraktion meldete nach Task-Abbruch nicht cancelled")
            return
        }

        let exitDeadline = Date().addingTimeInterval(2)
        while Darwin.kill(processPID, 0) == 0, Date() < exitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(Darwin.kill(processPID, 0) == -1 && errno == ESRCH)
    }
}
