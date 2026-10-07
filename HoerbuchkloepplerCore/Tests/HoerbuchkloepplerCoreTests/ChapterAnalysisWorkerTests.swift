import Testing
@testable import HoerbuchkloepplerCore
import Foundation
import Darwin

private final class ChapterWorkerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var executionCount = 0
    private var taskPresent = false
    private var mainThread = false
    private var unregisterCount = 0

    func recordExecution() {
        lock.withLock {
            executionCount += 1
            taskPresent = withUnsafeCurrentTask { $0 != nil }
            mainThread = Thread.isMainThread
        }
    }

    func recordUnregister() { lock.withLock { unregisterCount += 1 } }

    func snapshot() -> (executionCount: Int, taskPresent: Bool, mainThread: Bool, unregisterCount: Int) {
        lock.withLock { (executionCount, taskPresent, mainThread, unregisterCount) }
    }
}

private final class ChapterStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var entered = false
    private var processPID: pid_t = 0

    var hasEntered: Bool { lock.withLock { entered } }
    var pid: pid_t { lock.withLock { processPID } }

    func run(_ process: Process) throws -> Bool {
        lock.withLock { entered = true }
        guard release.wait(timeout: .now() + 3) == .success else { return false }
        try process.run()
        ProcessTerminator.recordOwnedProcessGroup(process)
        lock.withLock { processPID = process.processIdentifier }
        return true
    }

    func resume() { release.signal() }
}

@Suite("Kapitelanalyse – Worker")
struct ChapterAnalysisWorkerTests {
    @Test("Große Kapitelliste verlässt den kooperativen Task und behält ihre Werte")
    func largeChapterListRunsOutsideCooperativeTask() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChapterWorker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let count = 12_000
        let titleSuffix = String(repeating: "ä", count: 40)
        let metadata = ";FFMETADATA1\n" + (0..<count).map { index in
            "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(index * 1000)\nEND=\((index + 1) * 1000)\ntitle=Kapitel \(index) \(titleSuffix)\n"
        }.joined()
        let metadataURL = directory.appendingPathComponent("chapters.txt")
        try metadata.write(to: metadataURL, atomically: true, encoding: .utf8)
        let source = directory.appendingPathComponent("Buch.m4b")
        let found = FoundFile(source: source, resolved: source)
        let known = AudioFile(foundFile: found, startTime: 0, duration: Double(count), chapterTitle: "Buch")
        let probe = ChapterWorkerProbe()
        let start = ContinuousClock.now

        let result = await AudioFile.extractChaptersControlled(
            from: found,
            knownFile: known,
            configureProcess: { process in
                probe.recordExecution()
                process.executableURL = URL(fileURLWithPath: "/bin/cat")
                process.arguments = [metadataURL.path]
            },
            unregisterProcess: { process in
                ProcessTerminator.forgetOwnedProcessGroup(process)
                probe.recordUnregister()
            }
        )

        print("Kapitel-Worker-Probe: \(metadata.utf8.count) Bytes, \(count) Kapitel, \(start.duration(to: .now))")
        let execution = probe.snapshot()
        #expect(!execution.taskPresent)
        #expect(!execution.mainThread)
        #expect(execution.unregisterCount == 1)
        guard case .files(let files) = result else {
            Issue.record("Große Kapitelliste lieferte kein Ergebnis")
            return
        }
        guard files.count == count else {
            Issue.record("Erwartet: \(count) Kapitel, erhalten: \(files.count)")
            return
        }
        for index in [0, count / 2, count - 1] {
            #expect(files[index].startTime == Double(index))
            #expect(files[index].duration == 1)
            #expect(files[index].chapterTitle == "Kapitel \(index) \(titleSuffix)")
        }
    }

    @Test("Abbruch zwischen Startprüfung und Prozessstart hinterlässt keinen Prozess")
    func cancellationDuringProcessStart() async throws {
        let source = URL(fileURLWithPath: "/tmp/ChapterWorker-\(UUID().uuidString).m4b")
        let found = FoundFile(source: source, resolved: source)
        let gate = ChapterStartGate()
        let probe = ChapterWorkerProbe()
        let extraction = Task {
            await AudioFile.extractChaptersControlled(
                from: found,
                configureProcess: { process in
                    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
                    process.arguments = ["30"]
                },
                runProcess: { try gate.run($0) },
                unregisterProcess: { process in
                    ProcessTerminator.forgetOwnedProcessGroup(process)
                    probe.recordUnregister()
                }
            )
        }
        defer {
            gate.resume()
            extraction.cancel()
            if gate.pid > 0, Darwin.kill(gate.pid, 0) == 0 {
                _ = Darwin.kill(gate.pid, SIGKILL)
            }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while !gate.hasEntered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.hasEntered)
        let start = ContinuousClock.now
        extraction.cancel()
        gate.resume()
        let result = await extraction.value

        guard case .cancelled = result else {
            Issue.record("Abbruch während des Starts wurde nicht übernommen")
            return
        }
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(gate.pid > 0)
        #expect(Darwin.kill(gate.pid, 0) == -1 && errno == ESRCH)
        #expect(probe.snapshot().unregisterCount == 1)
    }

    @Test("Bereits abgebrochener Task startet keine Kapitelanalyse")
    func alreadyCancelledTaskDoesNotStartProcess() async {
        let source = URL(fileURLWithPath: "/tmp/ChapterWorker-\(UUID().uuidString).m4b")
        let found = FoundFile(source: source, resolved: source)
        let probe = ChapterWorkerProbe()
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await AudioFile.extractChaptersControlled(
                from: found,
                configureProcess: { _ in probe.recordExecution() }
            )
        }.value

        guard case .cancelled = result else {
            Issue.record("Bereits abgebrochener Task lieferte ein Ergebnis")
            return
        }
        #expect(probe.snapshot().unregisterCount == 0)
        #expect(probe.snapshot().executionCount == 0)
    }
}
