import Foundation
import Testing
@testable import HoerbuchkloepplerCore
import Darwin

@Suite("Ausgabeplanung und atomare Übernahme")
struct OutputSafetyTests {
    @Test("Der zentrale Plan nennt alle tatsächlichen Split-Ziele")
    func planContainsAllSplitOutputs() {
        let files = [1.0, 1.0, 1.0].map {
            AudioFile(url: URL(fileURLWithPath: "/tmp/source.mp3"), startTime: 0, duration: $0 * 3600, chapterTitle: "Kapitel")
        }
        let plan = FFmpegWrapper.makeConversionPlan(
            files: files,
            outputURL: URL(fileURLWithPath: "/tmp/Buch.m4b"),
            maxDurationHours: 2
        )
        #expect(plan.groups.map(\.count) == [2, 1])
        #expect(plan.outputURLs.map(\.lastPathComponent) == ["Buch-01.m4b", "Buch-02.m4b"])
    }

    @Test("Die bestehende Ausgabe bleibt bis zum atomaren Commit erhalten")
    func atomicCommitReplacesOnlyAtCommit() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = FFmpegWrapper.stagingOutputURL(for: final, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        try Data("alt".utf8).write(to: final)
        let expected = FFmpegWrapper.captureSnapshot(of: final)
        try Data("neu".utf8).write(to: staged)

        #expect(try String(contentsOf: final, encoding: .utf8) == "alt")
        try FFmpegWrapper.commitStagedOutput(
            staged,
            to: final,
            expectedDestination: expected
        )
        #expect(try String(contentsOf: final, encoding: .utf8) == "neu")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test("Eine leere Partial-Datei ersetzt keine bestehende Ausgabe")
    func emptyStagingDoesNotReplace() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = directory.appendingPathComponent(".Buch.partial.m4b")
        try Data("behalten".utf8).write(to: final)
        let expected = FFmpegWrapper.captureSnapshot(of: final)
        try Data().write(to: staged)

        #expect(throws: (any Error).self) {
            try FFmpegWrapper.commitStagedOutput(
                staged,
                to: final,
                expectedDestination: expected
            )
        }
        #expect(try String(contentsOf: final, encoding: .utf8) == "behalten")
    }

    @Test("Staging-Dateien tragen die Besitzer-PID als Laufmarke im Namen")
    func stagingURLCarriesOwnerPID() {
        let final = URL(fileURLWithPath: "/tmp/Buch.m4b")
        let staged = FFmpegWrapper.stagingOutputURL(for: final)
        #expect(FFmpegWrapper.stagedOutputOwnerPID(staged) == ProcessInfo.processInfo.processIdentifier)
    }

    @Test("Staging-Namen bleiben auch bei langen UTF-8-Titeln unter NAME_MAX")
    func stagingURLTruncatesLongBasenameByUTF8Bytes() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 125 Umlaute = 250 UTF-8-Bytes; der finale Name passt gerade noch,
        // der ungekürzte Staging-Zusatz dagegen nicht.
        let final = directory.appendingPathComponent(String(repeating: "ä", count: 125) + ".m4b")
        let staged = FFmpegWrapper.stagingOutputURL(for: final, ownerPID: 987_654)
        #expect(staged.lastPathComponent.utf8.count <= Int(NAME_MAX))

        try FFmpegWrapper.createOwnedStagingOutput(staged, ownerPID: 987_654)
        try Data("unvollständig".utf8).write(to: staged)
        FFmpegWrapper.removeOrphanedStagedOutputs(for: final)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test("Altformat-Partials ohne PID-Marke liefern keine Besitzer-PID")
    func legacyStagingNameHasNoOwner() {
        // Alte Namen waren `.partial-<uuid>`; eine rein numerische erste
        // UUID-Gruppe darf nicht als PID fehlinterpretiert werden.
        let legacy = URL(fileURLWithPath: "/tmp/.Buch.partial-12345678-1234-1234-1234-123456789012.m4b")
        #expect(FFmpegWrapper.stagedOutputOwnerPID(legacy) == nil)
        #expect(FFmpegWrapper.stagedOutputOwnerPID(URL(fileURLWithPath: "/tmp/Buch.m4b")) == nil)
    }

    @Test("Verwaiste Partial-Dateien toter Prozesse werden vor dem nächsten Lauf entfernt")
    func removesOrphanedStagedOutputs() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        // Oberhalb von macOS' PID_MAX (99999) — sicher kein lebender Prozess.
        let orphan = FFmpegWrapper.stagingOutputURL(for: final, ownerPID: 987_654)
        let alive = FFmpegWrapper.stagingOutputURL(for: final)
        let legacy = directory.appendingPathComponent(".Buch.partial-\(UUID().uuidString).m4b")
        let otherTarget = directory.appendingPathComponent(".Anderes.partial-987654-\(UUID().uuidString).m4b")
        try FFmpegWrapper.createOwnedStagingOutput(orphan, ownerPID: 987_654)
        try FFmpegWrapper.createOwnedStagingOutput(alive)
        try Data("unvollständig".utf8).write(to: orphan)
        try Data("unvollständig".utf8).write(to: alive)
        for url in [legacy, otherTarget] {
            try Data("unvollständig".utf8).write(to: url)
        }

        FFmpegWrapper.removeOrphanedStagedOutputs(for: final)

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        // Der eigene (lebende) Prozess, Altformat-Namen und fremde Ziele
        // bleiben unangetastet.
        #expect(FileManager.default.fileExists(atPath: alive.path))
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: otherTarget.path))
    }

    @Test("Case-insensitive Volumes entfernen abweichende Schreibweisen")
    func caseInsensitiveVolumeRemovesDifferentCasing() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let uppercaseFinal = directory.appendingPathComponent("BUCH.M4B")
        let lowercaseFinal = directory.appendingPathComponent("buch.m4b")
        let orphan = FFmpegWrapper.stagingOutputURL(for: uppercaseFinal, ownerPID: 987_654)
        try FFmpegWrapper.createOwnedStagingOutput(orphan, ownerPID: 987_654)
        try Data("unvollständig".utf8).write(to: orphan)

        FFmpegWrapper.removeOrphanedStagedOutputs(
            for: lowercaseFinal,
            caseSensitiveNames: false
        )

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test("Case-sensitive Volumes behalten abweichende Schreibweisen")
    func caseSensitiveVolumeKeepsDifferentCasing() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let uppercaseFinal = directory.appendingPathComponent("BUCH.M4B")
        let lowercaseFinal = directory.appendingPathComponent("buch.m4b")
        let orphan = FFmpegWrapper.stagingOutputURL(for: uppercaseFinal, ownerPID: 987_654)
        try FFmpegWrapper.createOwnedStagingOutput(orphan, ownerPID: 987_654)
        try Data("unvollständig".utf8).write(to: orphan)

        FFmpegWrapper.removeOrphanedStagedOutputs(
            for: lowercaseFinal,
            caseSensitiveNames: true
        )

        #expect(FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test("Ein Ziel mit `.partial-` im eigenen Namen wird trotzdem aufgeräumt")
    func handlesTargetNameContainingMarker() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // `sanitizeFilename` lässt Punkte und Bindestriche durch, ein solcher
        // Titel ist also über `--output` und den GUI-Speicherdialog erreichbar.
        let final = directory.appendingPathComponent("Mein.partial-Buch.m4b")
        // Oberhalb von macOS' PID_MAX (99999) — sicher kein lebender Prozess.
        let orphan = FFmpegWrapper.stagingOutputURL(for: final, ownerPID: 987_654)
        let alive = FFmpegWrapper.stagingOutputURL(for: final)

        // Erzeugen und Parsen müssen zusammenpassen: Nur der letzte Marker zählt.
        #expect(orphan.lastPathComponent.hasPrefix(".Mein.partial-Buch.partial-"))
        #expect(FFmpegWrapper.stagedOutputOwnerPID(orphan) == 987_654)
        #expect(FFmpegWrapper.stagedOutputOwnerPID(alive) == ProcessInfo.processInfo.processIdentifier)

        try FFmpegWrapper.createOwnedStagingOutput(orphan, ownerPID: 987_654)
        try FFmpegWrapper.createOwnedStagingOutput(alive)
        for url in [orphan, alive] {
            try Data("unvollständig".utf8).write(to: url)
        }

        FFmpegWrapper.removeOrphanedStagedOutputs(for: final)

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: alive.path))
    }

    @Test("Ein gleichnamiger Ordner wird nicht rekursiv gelöscht")
    func doesNotRemoveDirectoriesMatchingStagingName() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        // Gleicher Name wie eine verwaiste Partial-Datei, aber ein Ordner mit
        // Inhalt — der darf auf keinen Fall mitsamt Inhalt verschwinden.
        let decoyDirectory = FFmpegWrapper.stagingOutputURL(for: final, ownerPID: 987_654)
        try FileManager.default.createDirectory(at: decoyDirectory, withIntermediateDirectories: true)
        let payload = decoyDirectory.appendingPathComponent("wichtig.txt")
        try Data("nicht anfassen".utf8).write(to: payload)

        let logs = ThreadSafeLogProbe()
        FFmpegWrapper.removeOrphanedStagedOutputs(for: final, log: logs.append)

        #expect(FileManager.default.fileExists(atPath: decoyDirectory.path))
        #expect(FileManager.default.fileExists(atPath: payload.path))
        #expect(logs.snapshot().contains { $0.contains("Unmarkierter Staging-Eintrag") })
    }

    @Test("Ein nach der Typprüfung eingesetzter Ordner wird nicht rekursiv gelöscht")
    func doesNotRemoveDirectoryInsertedBeforeUnlink() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let orphan = FFmpegWrapper.stagingOutputURL(for: final, ownerPID: 987_654)
        try FFmpegWrapper.createOwnedStagingOutput(orphan, ownerPID: 987_654)
        try Data("unvollständig".utf8).write(to: orphan)
        var replacementError: (any Error)?
        let payload = orphan.appendingPathComponent("wichtig.txt")

        FFmpegWrapper.removeOrphanedStagedOutputs(for: final, beforeUnlink: { checkedURL in
            do {
                try FileManager.default.removeItem(at: checkedURL)
                try FileManager.default.createDirectory(
                    at: checkedURL,
                    withIntermediateDirectories: false
                )
                try Data("nicht anfassen".utf8).write(to: payload)
            } catch {
                replacementError = error
            }
        })

        #expect(replacementError == nil)
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: payload.path))
    }

    @Test("Verwaiste Partial-Dateien einer anderen Zielendung bleiben erhalten")
    func doesNotRemoveStagingFilesForDifferentExtension() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audiobook = directory.appendingPathComponent("Buch.m4b")
        let textFile = directory.appendingPathComponent("Buch.txt")
        let decoy = FFmpegWrapper.stagingOutputURL(for: textFile, ownerPID: 987_654)
        try Data("nicht anfassen".utf8).write(to: decoy)

        FFmpegWrapper.removeOrphanedStagedOutputs(for: audiobook)

        #expect(FileManager.default.fileExists(atPath: decoy.path))
    }

    @Test("Fortschritt mehrerer Split-Gruppen bleibt monoton")
    func splitProgressIsMonotonic() {
        let values = [
            FFmpegWrapper.mappedProgress(base: 0, weight: 0.5, phaseProgress: 0),
            FFmpegWrapper.mappedProgress(base: 0, weight: 0.5, phaseProgress: 0.5),
            FFmpegWrapper.mappedProgress(base: 0, weight: 0.5, phaseProgress: 1),
            FFmpegWrapper.mappedProgress(base: 0.5, weight: 0.5, phaseProgress: 0),
            FFmpegWrapper.mappedProgress(base: 0.5, weight: 0.5, phaseProgress: 1)
        ]

        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values.last == 1)
    }

    @Test("Sehr kurze Zeiten werden ohne Exponentialschreibweise an ffmpeg übergeben")
    func tinyTimesUseFixedDecimalArguments() {
        let file = AudioFile(
            url: URL(fileURLWithPath: "/tmp/kurz.m4b"),
            startTime: 0.00001,
            duration: 0.00002,
            chapterTitle: "Kurz"
        )
        let args = FFmpegWrapper.getArgsForStandardSlicing(
            file: file,
            url: URL(fileURLWithPath: "/tmp/kurz.wav"),
            settings: AudioSettings()
        )

        #expect(args[args.firstIndex(of: "-ss")! + 1] == "0.000010")
        #expect(args[args.firstIndex(of: "-t")! + 1] == "0.000020")
        #expect(!args.contains { $0.lowercased().contains("e-") })
    }

    @Test("Der finale ffmpeg-Fehler enthält dessen stderr-Ursache")
    @MainActor
    func finalProcessFailureIncludesStderr() async {
        let session = ConversionSession(settings: AudioSettings())
        let context = session.beginConversionRun()

        let succeeded = FFmpegWrapper.runFinalProcess(
            args: ["-nostdin", "-definitely-not-an-option"],
            session: session,
            context: context,
            progressBase: 0,
            progressWeight: 1,
            phaseDuration: 1,
            logMessage: "Testlauf",
            pacmanTitle: "Test"
        )
        for _ in 0..<10 where !session.eventLogs.contains(where: {
            $0.message.contains("Exit-Code")
        }) {
            await Task.yield()
        }

        #expect(!succeeded)
        let failure = session.eventLogs.first { $0.message.contains("Exit-Code") }?.message
        #expect(failure?.contains("Unrecognized option") == true)
    }

    @Test("Finale Ausgabe mit offen gehaltener Pipe gilt nicht als vollständig")
    @MainActor
    func finalProcessRejectsTruncatedPipeOutput() async throws {
        let directory = try makeTestDirectory()
        let wrapper = directory.appendingPathComponent("ffmpeg-wrapper")
        let childPIDFile = directory.appendingPathComponent("child.pid")
        defer {
            if let text = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let childPID = pid_t(text),
               Darwin.kill(childPID, 0) == 0 {
                _ = Darwin.kill(childPID, SIGKILL)
            }
            try? FileManager.default.removeItem(at: directory)
        }
        try writeExecutable(wrapper, """
        #!/usr/bin/python3
        import subprocess, sys
        child = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            stderr=sys.stderr,
            start_new_session=True,
        )
        with open(sys.argv[1], "w", encoding="utf-8") as handle:
            handle.write(str(child.pid))
        """)
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        let context = session.beginConversionRun()

        let succeeded = FFmpegWrapper.runFinalProcess(
            args: [childPIDFile.path],
            session: session,
            context: context,
            progressBase: 0,
            progressWeight: 1,
            phaseDuration: 1,
            logMessage: "Wrapper-Testlauf",
            pacmanTitle: "Test",
            executableURL: wrapper
        )
        for _ in 0..<10 where !session.eventLogs.contains(where: {
            $0.message.contains("unvollständig")
        }) {
            await Task.yield()
        }

        #expect(!succeeded)
        #expect(session.eventLogs.contains { $0.message.contains("unvollständig") })
    }

    @Test("Finaler Wrapper-Exit mit Hintergrund-Encoder gilt nicht als Erfolg")
    @MainActor
    func finalProcessRejectsBackgroundEncoder() async throws {
        let directory = try makeTestDirectory()
        let wrapper = directory.appendingPathComponent("ffmpeg-wrapper")
        let childPIDFile = directory.appendingPathComponent("child.pid")
        defer {
            if let text = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let childPID = pid_t(text),
               Darwin.kill(childPID, 0) == 0 {
                _ = Darwin.kill(childPID, SIGKILL)
            }
            try? FileManager.default.removeItem(at: directory)
        }
        try writeExecutable(wrapper, """
        #!/bin/sh
        /bin/sleep 30 </dev/null >/dev/null 2>&1 &
        printf '%s' "$!" > "$1"
        exit 0
        """)
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        let context = session.beginConversionRun()

        let succeeded = FFmpegWrapper.runFinalProcess(
            args: [childPIDFile.path],
            session: session,
            context: context,
            progressBase: 0,
            progressWeight: 1,
            phaseDuration: 1,
            logMessage: "Wrapper-Testlauf",
            pacmanTitle: "Test",
            executableURL: wrapper
        )
        let childPID = try #require(pid_t(String(
            contentsOf: childPIDFile,
            encoding: .utf8
        )))
        let deadline = Date().addingTimeInterval(2)
        while Darwin.kill(childPID, 0) == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<10 where !session.eventLogs.contains(where: {
            $0.message.contains("Hintergrundprozesse")
        }) {
            await Task.yield()
        }

        #expect(!succeeded)
        #expect(Darwin.kill(childPID, 0) == -1 && errno == ESRCH)
        #expect(session.eventLogs.contains {
            $0.message.contains("Hintergrundprozesse")
        })
    }
}

@Suite("Staging und atomarer Zieltausch")
struct StagingTransactionTests {
    @Test("Synchroner Startfehler wird dem GUI-Aufrufer zurückgegeben")
    @MainActor
    func conversionStartReturnsPlanFailure() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("eingang.wav")
        let output = directory.appendingPathComponent("ausgabe.m4b")
        try Data("eingang".utf8).write(to: input)
        let file = testAudioFile(input)
        let plan = FFmpegWrapper.makeConversionPlan(
            files: [file],
            outputURL: output,
            maxDurationHours: nil
        )
        try Data("fremd".utf8).write(to: output)
        let session = ConversionSession(settings: AudioSettings())
        session.audioFiles = [file]
        session.logSink = { _ in }

        let result = FFmpegWrapper.convert(session: session, plan: plan)

        guard case .rejected(let message) = result else {
            Issue.record("Geänderter Zielplan wurde trotzdem gestartet")
            return
        }
        #expect(message.contains("seit der Bestätigung verändert"))
        #expect(!session.showOverlay)
        #expect(session.lastConversionSucceeded == false)
    }

    @Test("Ein nach der Planung angelegtes Ziel wird nicht überschrieben")
    func missingDestinationUsesExclusiveRename() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = directory.appendingPathComponent(".staged.m4b")
        let expected = FFmpegWrapper.captureSnapshot(of: final)
        try Data("fremd".utf8).write(to: final)
        try Data("neu".utf8).write(to: staged)

        #expect(throws: ConversionOutputError.self) {
            try FFmpegWrapper.commitStagedOutput(
                staged,
                to: final,
                expectedDestination: expected
            )
        }
        #expect(try String(contentsOf: final, encoding: .utf8) == "fremd")
        #expect(try String(contentsOf: staged, encoding: .utf8) == "neu")
    }

    @Test("Der Ausgabeordner wird direkt vor dem Commit erneut geprüft")
    func outputDirectoryIsRecheckedImmediatelyBeforeCommit() throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outputDirectory = root.appendingPathComponent("Ausgabe")
        let parkedDirectory = root.appendingPathComponent("Ausgabe-alt")
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: false
        )
        let final = outputDirectory.appendingPathComponent("Buch.m4b")
        let staged = outputDirectory.appendingPathComponent(".staged.m4b")
        try Data("neu".utf8).write(to: staged)
        let expectedDirectory = FFmpegWrapper.captureSnapshot(
            of: outputDirectory,
            followSymlink: true
        )

        #expect(throws: ConversionOutputError.self) {
            try FFmpegWrapper.commitStagedOutput(
                staged,
                to: final,
                expectedDestination: .missing,
                expectedDestinationDirectory: expectedDirectory,
                beforeRename: {
                    try? FileManager.default.moveItem(
                        at: outputDirectory,
                        to: parkedDirectory
                    )
                    try? FileManager.default.createDirectory(
                        at: outputDirectory,
                        withIntermediateDirectories: false
                    )
                }
            )
        }
        #expect(!FileManager.default.fileExists(atPath: final.path))
        #expect(try String(
            contentsOf: parkedDirectory.appendingPathComponent(".staged.m4b"),
            encoding: .utf8
        ) == "neu")
    }

    @Test("Ein nach Bestätigung ausgetauschtes Ziel wird zurückbehalten")
    func changedDestinationIsNotReplaced() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = directory.appendingPathComponent(".staged.m4b")
        try Data("bestätigt".utf8).write(to: final)
        let expected = FFmpegWrapper.captureSnapshot(of: final)
        try FileManager.default.removeItem(at: final)
        try Data("inzwischen neu".utf8).write(to: final)
        try Data("Konvertierung".utf8).write(to: staged)

        #expect(throws: ConversionOutputError.self) {
            try FFmpegWrapper.commitStagedOutput(
                staged,
                to: final,
                expectedDestination: expected
            )
        }
        #expect(try String(contentsOf: final, encoding: .utf8) == "inzwischen neu")
        #expect(try String(contentsOf: staged, encoding: .utf8) == "Konvertierung")
    }

    @Test("Ein direkt vor dem Rename ausgetauschtes Staging wird zurückgerollt")
    func replacedStagingEntryIsNotCommitted() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = directory.appendingPathComponent(".staged.m4b")
        let replacement = directory.appendingPathComponent("fremd.m4b")
        try Data("bestätigtes Ziel".utf8).write(to: final)
        try Data("eigene Ausgabe".utf8).write(to: staged)
        try Data("fremder Ersatz".utf8).write(to: replacement)
        let expected = FFmpegWrapper.captureSnapshot(of: final)

        #expect(throws: ConversionOutputError.self) {
            try FFmpegWrapper.commitStagedOutput(
                staged,
                to: final,
                expectedDestination: expected,
                beforeRename: {
                    try? FileManager.default.removeItem(at: staged)
                    try? FileManager.default.moveItem(at: replacement, to: staged)
                }
            )
        }
        #expect(try String(contentsOf: final, encoding: .utf8) == "bestätigtes Ziel")
        #expect(try String(contentsOf: staged, encoding: .utf8) == "fremder Ersatz")
    }

    @Test("Ein vor dem Commit ausgetauschtes Staging wird nicht übernommen")
    func stagingOwnershipSpansCreationAndCommit() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = FFmpegWrapper.stagingOutputURL(for: final)
        try Data("bestätigtes Ziel".utf8).write(to: final)
        let expectedDestination = FFmpegWrapper.captureSnapshot(of: final)
        let ownership = try FFmpegWrapper.createOwnedStagingOutput(staged)
        try Data("eigene Ausgabe".utf8).write(to: staged)
        try FileManager.default.removeItem(at: staged)
        try Data("fremder Ersatz".utf8).write(to: staged)

        #expect(throws: ConversionOutputError.self) {
            try FFmpegWrapper.commitStagedOutput(
                staged,
                to: final,
                expectedDestination: expectedDestination,
                expectedStagingOwnership: ownership
            )
        }
        #expect(try String(contentsOf: final, encoding: .utf8) == "bestätigtes Ziel")
        #expect(try String(contentsOf: staged, encoding: .utf8) == "fremder Ersatz")
    }

    @Test("ffmpeg startet nicht mit einem ausgetauschten geschützten Staging-Pfad")
    @MainActor
    func protectedStagingIsRecheckedBeforeProcessStart() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let sentinel = directory.appendingPathComponent("wichtig.txt")
        try Data("nicht verändern".utf8).write(to: sentinel)
        let staging = try FFmpegWrapper.createProtectedStagingOutput(for: final)
        try FileManager.default.removeItem(at: staging.url)
        try FileManager.default.createSymbolicLink(
            at: staging.url,
            withDestinationURL: sentinel
        )
        let session = ConversionSession(settings: AudioSettings())
        let context = session.beginConversionRun()

        let succeeded = FFmpegWrapper.runFinalProcess(
            args: ["-version"],
            session: session,
            context: context,
            progressBase: 0,
            progressWeight: 1,
            phaseDuration: 1,
            logMessage: "Testlauf",
            pacmanTitle: "Test",
            stagingURL: staging.url,
            expectedStagingOwnership: staging.ownership
        )

        #expect(!succeeded)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "nicht verändern")
    }

    @Test("ffmpeg schreibt nach der Vorprüfung weiter auf den geöffneten Staging-Inode")
    @MainActor
    func finalProcessOutputIsBoundToDescriptor() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staging = try FFmpegWrapper.createProtectedStagingOutput(for: final)
        let protectedDirectory = try #require(
            staging.ownership.protectedDirectory
        )
        let parkedDirectory = directory.appendingPathComponent("geparktes-staging")
        let decoyDirectory = directory.appendingPathComponent("fremdes-ziel")
        try FileManager.default.createDirectory(
            at: decoyDirectory,
            withIntermediateDirectories: false
        )
        let decoy = decoyDirectory.appendingPathComponent("entry.m4b")
        try Data("nicht verändern".utf8).write(to: decoy)
        let session = ConversionSession(settings: AudioSettings())
        let context = session.beginConversionRun()
        var hookError: (any Error)?

        let succeeded = FFmpegWrapper.runFinalProcess(
            args: [
                "-nostdin", "-y", "-f", "lavfi", "-i",
                "sine=frequency=1000:duration=0.05",
                "-c:a", "aac", "-f", "ipod", "/dev/fd/0"
            ],
            session: session,
            context: context,
            progressBase: 0,
            progressWeight: 1,
            phaseDuration: 0.05,
            logMessage: "Testlauf",
            pacmanTitle: "Test",
            stagingURL: staging.url,
            expectedStagingOwnership: staging.ownership,
            stagingHandle: staging,
            beforeProcessStart: {
                do {
                    try FileManager.default.moveItem(
                        at: protectedDirectory,
                        to: parkedDirectory
                    )
                    try FileManager.default.createSymbolicLink(
                        at: protectedDirectory,
                        withDestinationURL: decoyDirectory
                    )
                } catch {
                    hookError = error
                }
            }
        )

        #expect(hookError == nil)
        #expect(succeeded)
        #expect(try String(contentsOf: decoy, encoding: .utf8) == "nicht verändern")
        #expect(FFmpegWrapper.regularFileSize(
            parkedDirectory.appendingPathComponent("entry.m4b")
        ) != nil)
    }

    @Test("Neue Ausgaben behalten allgemein lesbare Dateirechte")
    func committedOutputUsesExpectedPermissions() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = FFmpegWrapper.stagingOutputURL(for: final)
        let ownership = try FFmpegWrapper.createOwnedStagingOutput(staged)
        try Data("Ausgabe".utf8).write(to: staged)

        _ = try FFmpegWrapper.commitStagedOutput(
            staged,
            to: final,
            expectedDestination: .missing,
            expectedStagingOwnership: ownership
        )

        let identity = try #require(
            FFmpegWrapper.fileSystemIdentity(at: final, followSymlink: false)
        )
        #expect(identity.mode & mode_t(0o777) == mode_t(0o644))
    }

    @Test("Der Datei-Snapshot trennt Inhalt, Dateityp und Statuszeit")
    func fileSystemIdentityPredicatesSeparateContentFromMetadata() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Quelle.m4b")
        try Data("Inhalt".utf8).write(to: file)
        let baseline = try #require(
            FFmpegWrapper.fileSystemIdentity(at: file, followSymlink: false)
        )

        // Ein `chmod` ändert Rechte und Statuszeit, nicht den Inhalt.
        #expect(chmod(file.path, 0o600) == 0)
        let afterChmod = try #require(
            FFmpegWrapper.fileSystemIdentity(at: file, followSymlink: false)
        )
        #expect(baseline.matchesContentSnapshot(afterChmod))
        #expect(baseline.matchesDisplacedEntry(afterChmod))
        #expect(baseline != afterChmod)

        // Ein Finder-Tag hebt allein die Statuszeit.
        var tag: [UInt8] = [0x41]
        #expect(setxattr(
            file.path,
            "com.apple.metadata:_kMDItemUserTags",
            &tag,
            tag.count,
            0,
            0
        ) == 0)
        let afterTag = try #require(
            FFmpegWrapper.fileSystemIdentity(at: file, followSymlink: false)
        )
        #expect(afterChmod.matchesContentSnapshot(afterTag))
        #expect(afterChmod.matchesDisplacedEntry(afterTag))
        #expect(afterChmod != afterTag)

        // Neuer Inhalt schlägt in allen drei Prädikaten durch.
        try Data("Anderer, längerer Inhalt".utf8).write(to: file)
        let afterWrite = try #require(
            FFmpegWrapper.fileSystemIdentity(at: file, followSymlink: false)
        )
        #expect(!afterTag.matchesContentSnapshot(afterWrite))
        #expect(!afterTag.matchesDisplacedEntry(afterWrite))
        #expect(afterTag != afterWrite)
    }

    @Test("Rechteänderung am Ziel widerspricht dem bestätigten Inhalt nicht")
    func destinationPermissionChangeDoesNotForceRollback() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = directory.appendingPathComponent(".staged.m4b")
        try Data("altes Ziel".utf8).write(to: final)
        try Data("neue Ausgabe".utf8).write(to: staged)
        let expected = FFmpegWrapper.captureSnapshot(of: final)

        let removed = try FFmpegWrapper.commitStagedOutput(
            staged,
            to: final,
            expectedDestination: expected,
            beforeRename: { #expect(chmod(final.path, 0o600) == 0) }
        )

        #expect(removed)
        #expect(try String(contentsOf: final, encoding: .utf8) == "neue Ausgabe")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test("Ein Finder-Tag an der Altdatei kostet nicht die fertige Ausgabe")
    func metadataOnlyDestinationChangeStillCommits() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        try Data("alt".utf8).write(to: final)
        let expected = FFmpegWrapper.captureSnapshot(of: final)
        let staging = try FFmpegWrapper.createProtectedStagingOutput(for: final)
        try Data("fertiges Hörbuch".utf8).write(to: staging.url)

        // Spotlight, Time Machine oder ein Finder-Tag fassen die Altdatei
        // während des stundenlangen Encodings an: Inhalt, Größe und
        // Änderungszeit bleiben gleich, nur die Statuszeit steigt.
        var tag: [UInt8] = [0x41]
        #expect(setxattr(
            final.path,
            "com.apple.metadata:_kMDItemUserTags",
            &tag,
            tag.count,
            0,
            0
        ) == 0)

        _ = try FFmpegWrapper.commitStagedOutput(
            staging.url,
            to: final,
            expectedDestination: expected,
            expectedStagingOwnership: staging.ownership
        )

        #expect(try String(contentsOf: final, encoding: .utf8) == "fertiges Hörbuch")
    }

    @Test("Ein erfolgreicher geschützter Commit entfernt seinen Staging-Ordner")
    func protectedCommitRemovesStagingDirectory() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        try Data("alt".utf8).write(to: final)
        let expected = FFmpegWrapper.captureSnapshot(of: final)
        let staging = try FFmpegWrapper.createProtectedStagingOutput(for: final)
        try Data("neu".utf8).write(to: staging.url)
        let context = ConversionContext()
        context.registerStagedOutput(
            staging.url,
            ownership: staging.ownership
        )

        let removed = try FFmpegWrapper.commitStagedOutput(
            staging.url,
            to: final,
            expectedDestination: expected,
            expectedStagingOwnership: staging.ownership
        )
        #expect(removed)
        context.completeStagedOutput(staging.url)

        #expect(try String(contentsOf: final, encoding: .utf8) == "neu")
        #expect(!FileManager.default.fileExists(
            atPath: try #require(staging.ownership.protectedDirectory).path
        ))
    }

    @Test("Volumes ohne Extended Attributes nutzen den Inode-Laufzeitbesitz")
    func unsupportedStagingMarkerFallsBackToRuntimeIdentity() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = FFmpegWrapper.stagingOutputURL(
            for: directory.appendingPathComponent("Buch.m4b")
        )
        let ownership = try FFmpegWrapper.createOwnedStagingOutput(
            staged,
            setOwnershipMarker: { _, _ in
                errno = ENOTSUP
                return -1
            }
        )
        try Data("unvollständig".utf8).write(to: staged)
        let context = ConversionContext()
        context.registerStagedOutput(staged, ownership: ownership)

        #expect(!ownership.hasPersistentMarker)
        #expect(context.cancel())
        #expect(context.waitForCancellationCleanup())
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test("Fehler beim Markieren löscht keinen Ersatz am Staging-Pfad")
    func stagingMarkerFailurePreservesReplacement() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = FFmpegWrapper.stagingOutputURL(
            for: directory.appendingPathComponent("Buch.m4b")
        )
        let movedCreation = directory.appendingPathComponent("eigener-inode.m4b")
        var hookError: (any Error)?

        #expect(throws: POSIXError.self) {
            try FFmpegWrapper.createOwnedStagingOutput(
                staged,
                setOwnershipMarker: { _, _ in
                    do {
                        try FileManager.default.moveItem(
                            at: staged,
                            to: movedCreation
                        )
                        try Data("fremder Ersatz".utf8).write(to: staged)
                    } catch {
                        hookError = error
                    }
                    errno = EPERM
                    return -1
                }
            )
        }

        #expect(hookError == nil)
        #expect(try String(contentsOf: staged, encoding: .utf8) == "fremder Ersatz")
        #expect(FileManager.default.fileExists(atPath: movedCreation.path))
    }

    @Test("Der Produktions-Catch löscht ein zurückgerolltes fremdes Staging nicht")
    func stagingRaceCatchPreservesReplacement() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = FFmpegWrapper.stagingOutputURL(for: final)
        let replacement = directory.appendingPathComponent("fremd.m4b")
        try Data("bestätigtes Ziel".utf8).write(to: final)
        try FFmpegWrapper.createOwnedStagingOutput(staged)
        try Data("eigene Ausgabe".utf8).write(to: staged)
        try Data("fremder Ersatz".utf8).write(to: replacement)
        let expected = FFmpegWrapper.captureSnapshot(of: final)
        let context = ConversionContext()
        context.registerStagedOutput(staged)

        do {
            _ = try FFmpegWrapper.commitStagedOutput(
                staged,
                to: final,
                expectedDestination: expected,
                beforeRename: {
                    try? FileManager.default.removeItem(at: staged)
                    try? FileManager.default.moveItem(at: replacement, to: staged)
                }
            )
            Issue.record("Staging-Austausch blieb unentdeckt")
        } catch {
            context.handleCommitFailure(error, stagedURL: staged)
        }

        #expect(try String(contentsOf: final, encoding: .utf8) == "bestätigtes Ziel")
        #expect(try String(contentsOf: staged, encoding: .utf8) == "fremder Ersatz")
    }
}
