import Foundation
import Testing
@testable import HoerbuchkloepplerCore
import Darwin

/// Hält fest, auf welchem Thread ein Log entstanden ist. Für die Frage, ob die
/// Abbruchbereinigung den Aufrufer blockiert, zählt allein: nicht auf seinem.
private final class CallerThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let callerThread: Thread
    private var logs = 0
    private var onCallerThread = 0

    init(callerThread: Thread) { self.callerThread = callerThread }

    func record() {
        lock.lock()
        logs += 1
        if Thread.current === callerThread { onCallerThread += 1 }
        lock.unlock()
    }

    func snapshot() -> (logs: Int, onCallerThread: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (logs, onCallerThread)
    }
}

/// Deterministische Schranke für Race-Tests: Der Hintergrund-Thread meldet,
/// dass er den kritischen Abschnitt erreicht hat, und wartet auf die Freigabe.
private final class BlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = false
    private var released = false

    func blockUntilReleased() {
        condition.lock()
        blocked = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilBlocked() {
        condition.lock()
        while !blocked {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private actor PreparationCancellationProbe {
    private var started = false
    private var observedCancellation = false

    func markStarted() { started = true }
    func markFinished(cancelled: Bool) { observedCancellation = cancelled }
    func snapshot() -> (started: Bool, observedCancellation: Bool) {
        (started, observedCancellation)
    }
}

@Suite("Vorbereitungs- und Konvertierungsabbruch")
@MainActor
struct CancellationIsolationTests {
    @Test("Ein vor dem Ordnerscan abgebrochener Lauf bleibt als Abbruch erkennbar")
    func cancelledFolderScanIsMarkedAsCancelled() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = ConversionSession(settings: AudioSettings())

        session.beginPreparation()
        #expect(session.cancelPreparation())

        let scanned = await session.scanFolder(directory)

        #expect(scanned.wasCancelled)
        #expect(scanned.audioFiles.isEmpty)
        #expect(scanned.imageURLs.isEmpty)
    }

    @Test("Der explizite Dateiimport startet nach Vorbereitungsabbruch keine Analyse")
    func orderedFileImportRetainsPreparationCancellation() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Kapitel.wav")
        try writeSilentWAV(to: file)
        let session = ConversionSession(settings: AudioSettings())
        session.beginPreparation()
        #expect(session.cancelPreparation())

        await session.importFiles([file], usingExistingPreparation: true)

        #expect(session.importService.metrics.sourceAnalyses == 0)
        #expect(session.audioFiles.isEmpty)
        #expect(!session.isImporting)
    }

    @Test("Ein neuer Dateiimport löst sich von der abgebrochenen Vorbereitung")
    func orderedFileImportCanRetry() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Kapitel.wav")
        try writeSilentWAV(to: file)
        let session = ConversionSession(settings: AudioSettings())
        session.beginPreparation()
        #expect(session.cancelPreparation())

        await session.importFiles([file], analyzeArtwork: false)

        #expect(session.audioFiles.map(\.name) == ["Kapitel.wav"])
        #expect(!session.isImporting)
    }

    @Test("Vorbereitungsabbruch cancelt den registrierten Swift-Task")
    func preparationCancellationReachesTask() async throws {
        let session = ConversionSession(settings: AudioSettings())
        let probe = PreparationCancellationProbe()
        session.beginPreparation()
        let work = Task {
            await session.runPreparationTask {
                await probe.markStarted()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    // CancellationError ist hier das erwartete Ende.
                }
                await probe.markFinished(cancelled: Task.isCancelled)
            }
        }

        var state = await probe.snapshot()
        var attempts = 0
        while !state.started, attempts < 1_000 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(1))
            state = await probe.snapshot()
        }
        guard state.started else {
            work.cancel()
            await work.value
            Issue.record("Vorbereitungstask startete nicht innerhalb einer Sekunde")
            return
        }

        #expect(session.cancelPreparation())
        await work.value
        state = await probe.snapshot()
        #expect(state.observedCancellation)
        #expect(!session.cancelPreparation())
    }

    @Test("Import-Abbrechen beendet registrierte Tasks und ignoriert verspätete Beiträge")
    func userCancellationPreservesExistingBook() async throws {
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        let original = AudioFile(url: URL(fileURLWithPath: "/tmp/Alt.wav"), startTime: 2, duration: 4, chapterTitle: "Bearbeitet")
        session.audioFiles = [original]
        session.title = "Mein Titel"
        session.author = "Autor"
        session.removeCover()
        let token = session.beginImport(expectedItemCount: 2)
        let incoming = AudioFile(url: URL(fileURLWithPath: "/tmp/Neu.wav"), startTime: 0, duration: 3, chapterTitle: "Neu")
        session.stageAudioLoadResult(.success(files: [incoming], warnings: []), importToken: token)
        await session.finishImport(token)
        #expect(session.importCompletedItems == 1)
        #expect(session.importTotalItems == 2)
        let probe = PreparationCancellationProbe()
        let work = Task {
            await session.runImportTask(token) {
                await probe.markStarted()
                do { try await Task.sleep(for: .seconds(30)) } catch { }
                await probe.markFinished(cancelled: Task.isCancelled)
            }
        }
        for _ in 0..<1_000 {
            if await probe.snapshot().started { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await probe.snapshot().started)
        session.cancelImport()
        await work.value
        #expect(await probe.snapshot().observedCancellation)
        session.stageAudioLoadResult(.success(files: [incoming], warnings: []), importToken: token)
        await session.finishImport(token)
        #expect(session.audioFiles.map(\.id) == [original.id])
        #expect(session.audioFiles.first?.chapterTitle == "Bearbeitet")
        #expect(session.title == "Mein Titel")
        #expect(session.author == "Autor")
        #expect(session.isCoverSuppressed)
        #expect(!session.isImporting)
        let nextToken = session.beginImport()
        await session.runImportTask(token) { Issue.record("Alter Provider startete erneut") }
        await session.finishImport(token)
        #expect(session.isImporting)
        #expect(session.importCompletedItems == 0)
        session.stageAudioLoadResult(.skipped, importToken: nextToken)
        await session.finishImport(nextToken)
        #expect(!session.isImporting)
    }

    @Test("Ein neuer GUI-Drop cancelt den laufenden Import-Task")
    func replacementImportCancelsRunningTask() async throws {
        let session = ConversionSession(settings: AudioSettings())
        let probe = PreparationCancellationProbe()
        let staleToken = session.beginImport()
        let work = Task {
            await session.runImportTask(staleToken) {
                await probe.markStarted()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    // CancellationError ist beim ersetzenden Drop erwartet.
                }
                await probe.markFinished(cancelled: Task.isCancelled)
            }
        }

        var state = await probe.snapshot()
        var attempts = 0
        while !state.started, attempts < 1_000 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(1))
            state = await probe.snapshot()
        }
        guard state.started else {
            work.cancel()
            await work.value
            Issue.record("GUI-Import-Task startete nicht innerhalb einer Sekunde")
            return
        }

        _ = session.beginImport()
        await work.value
        state = await probe.snapshot()
        #expect(state.observedCancellation)
    }

    @Test("Abbruch räumt nur Ressourcen seines Laufs auf")
    func contextsAreIsolated() throws {
        let firstDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HB_Temp_\(UUID().uuidString)")
        let secondDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HB_Temp_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: firstDirectory) }
        defer { try? FileManager.default.removeItem(at: secondDirectory) }
        try FFmpegWrapper.createOwnedTempDirectory(firstDirectory)
        try FFmpegWrapper.createOwnedTempDirectory(secondDirectory)
        let first = ConversionContext()
        let second = ConversionContext()
        first.registerTempDirectory(firstDirectory)
        second.registerTempDirectory(secondDirectory)

        first.cancel()
        #expect(first.waitForCancellationCleanup())

        #expect(first.isCancelled)
        #expect(!second.isCancelled)
        #expect(!FileManager.default.fileExists(atPath: firstDirectory.path))
        #expect(FileManager.default.fileExists(atPath: secondDirectory.path))
    }

    @Test("Ein Neustart macht nur die alte Completion ungültig")
    func rapidRestartKeepsNewContext() {
        let session = ConversionSession()
        let first = session.beginConversionRun()
        let second = session.beginConversionRun()
        #expect(first.isCancelled)
        #expect(session.isCurrentConversion(second.id))
        session.endConversion(first.id)
        #expect(session.isCurrentConversion(second.id))
    }

    @Test("Ereignisse eines alten Laufs erreichen den neuen Lauf nicht")
    func staleWorkerEventsAreDiscardedAfterRestart() async {
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        let first = session.beginConversionRun()
        session.enqueueLog("Veralteter Lauf", runID: first.id)

        let second = session.beginConversionRun()
        session.enqueueLog("Aktueller Lauf", runID: second.id)
        await session.flushConversionEvents()

        #expect(session.eventLogs.map(\.message) == ["Aktueller Lauf"])
        #expect(first.isCancelled)
        #expect(session.isCurrentConversion(second.id))
    }

    @Test("Reset, Fortschritt, Log und Abschluss bleiben in Sendereihenfolge")
    func workerEventsRemainOrderedThroughCompletion() async {
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        let context = session.beginConversionRun()
        let output = URL(fileURLWithPath: "/tmp/Buch.m4b")

        session.enqueueSegmentReset(title: "Finaler Lauf", runID: context.id)
        session.enqueueSegmentInitialization(index: 1, filename: "Kapitel", runID: context.id)
        session.enqueueProgress(
            0.6,
            segmentIndex: 1,
            segmentProgress: 0.5,
            runID: context.id
        )
        session.enqueueLog("Vor dem Abschluss", runID: context.id)
        session.enqueueConversionFinished(
            success: false,
            cancelled: false,
            completedOutputs: [output],
            runID: context.id
        )
        await session.flushConversionEvents()

        #expect(session.segmentProgress[0]?.filename == "Finaler Lauf")
        #expect(session.segmentProgress[1] == SegmentStatus(filename: "Kapitel", progress: 0.5))
        #expect(session.progress == 0.6)
        #expect(session.eventLogs.map(\.message) == [
            "Vor dem Abschluss",
            "🏁 Vorgang mit Fehlern beendet."
        ])
        #expect(session.completedOutputURLs == [output])
        #expect(session.lastConversionSucceeded == false)
        #expect(!session.isCurrentConversion(context.id))
    }

    @Test("Abbruch entfernt auch die laufbezogene Partial-Datei")
    func cancellationRemovesStagedOutput() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = FFmpegWrapper.stagingOutputURL(
            for: directory.appendingPathComponent("Buch.m4b")
        )
        try FFmpegWrapper.createOwnedStagingOutput(staged)
        try Data("unvollständig".utf8).write(to: staged)
        let context = ConversionContext()
        context.registerStagedOutput(staged)

        #expect(context.cancel())
        #expect(context.waitForCancellationCleanup())
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test("Ein bereits abgebrochener Lauf startet keinen neuen Prozess")
    func cancelledContextRejectsProcessStart() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("unerwartet-gestartet")
        let context = ConversionContext()
        #expect(context.cancel())

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        process.arguments = [sentinel.path]

        #expect(try !context.run(process))
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test("SIGTERM-resistenter Prozess wird vor der Dateibereinigung beendet")
    func cancellationEscalatesAndThenCleansFiles() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = FFmpegWrapper.stagingOutputURL(
            for: directory.appendingPathComponent("Buch.m4b")
        )
        try FFmpegWrapper.createOwnedStagingOutput(staged)
        let context = ConversionContext()
        context.registerStagedOutput(staged)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Die Warteschleife schläft, statt zu rechnen. Ein Busy-Loop sättigt
        // einen Kern, solange die übrige Suite parallel läuft, und lässt
        // zeitkritische Joins hier und in anderen Tests unter Last auslaufen.
        // Am Verhalten ändert das nichts: SIGTERM löst nur den Trap aus, die
        // Schleife läuft weiter und der Prozess endet erst durch SIGKILL.
        process.arguments = [
            "-c",
            "trap 'printf late > \"$1\"' TERM; printf READY; "
                + "while :; do /bin/sleep 0.05; done",
            "hoerbuchkloeppler-test",
            staged.path
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        defer {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }

        #expect(try context.run(process))
        let ready = output.fileHandleForReading.readData(ofLength: 5)
        #expect(String(data: ready, encoding: .utf8) == "READY")

        // Eigene Threads statt der globalen Queue: Laufen alle Suiten parallel,
        // blockieren ihre Prozess-Joins den Dispatch-Pool, und ein hier
        // eingereihter Block kann sekundenlang auf einen Thread warten. Das ließ
        // diesen Test unter Volllast etwa jeden dritten Lauf auslaufen.
        let workerFinished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            process.waitUntilExit()
            workerFinished.signal()
        }
        #expect(context.cancel())
        let cleanupFinished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            context.finishAfterCancellationCleanup { _ in }
            cleanupFinished.signal()
        }

        // Der komplette Swift-Testing-Lauf startet mehrere echte Prozesse
        // parallel. Die Produktions-Schonfrist bleibt 0,5 Sekunden; nur der
        // Test-Join erhält genug Spielraum für belastete CI-/Entwicklungs-Macs.
        let cleanupResult = cleanupFinished.wait(timeout: .now() + 5)
        let workerResult = workerFinished.wait(timeout: .now() + 5)

        #expect(cleanupResult == .success)
        #expect(workerResult == .success)
        #expect(!process.isRunning)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test("Die Abbruchbereinigung läuft auch ohne laufenden Prozess nicht auf dem Aufrufer")
    func cancellationCleanupLeavesCallerThread() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = FFmpegWrapper.stagingOutputURL(
            for: directory.appendingPathComponent("Buch.m4b")
        )
        let ownership = try FFmpegWrapper.createOwnedStagingOutput(staged)
        let probe = CallerThreadProbe(callerThread: Thread.current)
        let context = ConversionContext { _, _ in probe.record() }
        context.registerStagedOutput(staged, ownership: ownership)
        // Ein fremder Ersatz an derselben Stelle: Die Bereinigung lässt ihn
        // liegen und meldet das. Erst diese Meldung macht überhaupt sichtbar,
        // auf welchem Thread die Bereinigung läuft.
        try FileManager.default.removeItem(at: staged)
        try Data("fremd".utf8).write(to: staged)

        // Kein Prozess registriert: Genau dann lief die Bereinigung früher
        // synchron auf dem Aufrufer — in der GUI also auf dem Main Actor,
        // samt rekursivem Löschen mehrerer Gigabyte.
        #expect(context.cancel())

        let cleanupFinished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            context.finishAfterCancellationCleanup { _ in }
            cleanupFinished.signal()
        }
        #expect(cleanupFinished.wait(timeout: .now() + 5) == .success)

        let observed = probe.snapshot()
        #expect(observed.logs > 0)
        #expect(observed.onCallerThread == 0)
    }

    @Test("Abbruchmeldung und Bereinigungswarnung gehen dem Abschluss voraus")
    func cancellationCleanupPrecedesTerminalEvent() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stagedDirectory = directory.appendingPathComponent(".Buch.partial-race.m4b")
        try FileManager.default.createDirectory(
            at: stagedDirectory,
            withIntermediateDirectories: true
        )

        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        let context = session.beginConversionRun()
        context.registerStagedOutput(stagedDirectory)
        let cancellationGate = BlockingGate()

        let cancellation = Task.detached {
            context.cancel {
                session.enqueueCancellationStarted(runID: context.id)
                cancellationGate.blockUntilReleased()
            }
        }
        cancellationGate.waitUntilBlocked()

        let finish = Task.detached {
            context.finishAfterCancellationCleanup { cancelled in
                session.enqueueConversionFinished(
                    success: false,
                    cancelled: cancelled,
                    completedOutputs: [],
                    runID: context.id
                )
            }
        }
        cancellationGate.release()

        #expect(await cancellation.value)
        await finish.value
        await session.flushConversionEvents()

        let messages = session.eventLogs.map(\.message)
        #expect(messages.count == 2)
        #expect(messages.first == "🛑 Vorgang wird abgebrochen und bereinigt.")
        #expect(messages.last?.contains("keine gültige Besitzer-Markierung") == true)
        #expect(session.conversionStatus == "Abgebrochen")
        #expect(!session.isCurrentConversion(context.id))
    }

    @Test("Cancel und Commit haben eine eindeutige Reihenfolge")
    func commitAndCancellationAreSerialized() throws {
        let cancelledContext = ConversionContext()
        #expect(cancelledContext.cancel())
        var mutationRan = false
        let committedAfterCancel = try cancelledContext.performCommit(isLastOutput: true) {
            mutationRan = true
        }
        #expect(!committedAfterCancel)
        #expect(!mutationRan)

        let finishedContext = ConversionContext()
        let committedBeforeCancel = try finishedContext.performCommit(isLastOutput: true) {
            mutationRan = true
        }
        #expect(committedBeforeCancel)
        // Ohne diese Zeile käme ein `performCommit` durch, das Erfolg meldet,
        // ohne die Übernahme überhaupt auszuführen.
        #expect(mutationRan)
        #expect(!finishedContext.cancel())
    }

    @Test("Der Abschluss übernimmt die erfolgreichen Ziel-URLs in einer Nachricht")
    func conversionFinishCarriesCompletedOutputs() async {
        let session = ConversionSession(settings: AudioSettings())
        let context = session.beginConversionRun()
        let url = URL(fileURLWithPath: "/tmp/Buch-01.m4b")

        session.enqueueConversionFinished(
            success: false,
            cancelled: false,
            completedOutputs: [url],
            runID: context.id
        )
        await session.flushConversionEvents()

        // Auch bei einem Teilerfolg (success == false) kennt die Session damit
        // die bereits atomar übernommenen Dateien — die CLI listet sie auf,
        // statt fälschlich "keine gültige Datei" zu melden.
        #expect(session.lastConversionSucceeded == false)
        #expect(session.completedOutputURLs == [url])
    }

    @Test("Temporäres Verzeichnis erkennt den lebenden Besitzer")
    func temporaryDirectoryRecognizesLiveOwner() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HB_Temp_Test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FFmpegWrapper.createOwnedTempDirectory(directory)

        #expect(FFmpegWrapper.temporaryDirectoryHasLiveOwner(directory))
    }

    /// Der Positivfall allein genügt nicht: Fiele die Lebendprüfung weg, bliebe
    /// er grün, und verwaiste Temp-Verzeichnisse toter Läufe lägen für immer
    /// als Gigabyte-Leichen herum.
    @Test("Ohne Marke und mit totem Besitzer gilt ein Verzeichnis als verwaist")
    func temporaryDirectoryRejectsMissingAndDeadOwner() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HB_Temp_Test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let unmarked = root.appendingPathComponent("ohne-marke")
        try FileManager.default.createDirectory(at: unmarked, withIntermediateDirectories: true)
        #expect(!FFmpegWrapper.temporaryDirectoryHasLiveOwner(unmarked))

        let dead = root.appendingPathComponent("toter-besitzer")
        try FFmpegWrapper.createOwnedTempDirectory(dead)
        // Ein kurzlebiges Kind liefert eine PID, die beim Prüfen sicher tot ist.
        let corpse = Process()
        corpse.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try corpse.run()
        corpse.waitUntilExit()
        try Data(String(corpse.processIdentifier).utf8)
            .write(to: dead.appendingPathComponent(".owner-pid"))
        #expect(!FFmpegWrapper.temporaryDirectoryHasLiveOwner(dead))
    }
}
