import Foundation
import Testing
@testable import HoerbuchkloepplerCore
import Darwin

@Suite("Ausgabeplanung – Kapitel gruppieren")
struct SplitAudioFilesTests {

    private func file(_ hours: Double) -> AudioFile {
        AudioFile(url: URL(fileURLWithPath: "/tmp/a.mp3"), startTime: 0, duration: hours * 3600, chapterTitle: "x")
    }

    @Test("Ohne Maximaldauer bleibt alles eine Gruppe")
    func noMaxDuration() {
        let groups = ConversionPlanner.splitAudioFilesIfNeeded([file(1), file(1)], maxDurationHours: nil)
        #expect(groups.count == 1)
        #expect(groups[0].count == 2)
    }

    @Test("Maximaldauer 0 bedeutet unbegrenzt")
    func zeroMeansUnlimited() {
        let groups = ConversionPlanner.splitAudioFilesIfNeeded([file(1), file(1)], maxDurationHours: 0)
        #expect(groups.count == 1)
    }

    @Test("Wird die Maximaldauer überschritten, entsteht eine neue Gruppe")
    func splitsWhenExceeded() {
        // 3 x 4h bei max 10h -> [4h+4h], [4h]
        let groups = ConversionPlanner.splitAudioFilesIfNeeded([file(4), file(4), file(4)], maxDurationHours: 10)
        #expect(groups.count == 2)
        #expect(groups[0].count == 2)
        #expect(groups[1].count == 1)
    }

    @Test("Passt genau auf die Grenze, bleibt es eine Gruppe")
    func exactFitStaysOneGroup() {
        let groups = ConversionPlanner.splitAudioFilesIfNeeded([file(5), file(5)], maxDurationHours: 10)
        #expect(groups.count == 1)
    }

    @Test("Kapitelzeiten außerhalb der FFmetadata-Skala stoppen den Start")
    @MainActor
    func invalidEncodingTimelineDoesNotStart() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Quelle.wav")
        try Data([0]).write(to: source)
        let output = directory.appendingPathComponent("Buch.m4b")
        let session = ConversionSession(settings: AudioSettings())
        session.audioFiles = [AudioFile(url: source, startTime: 0, duration: Double(Int64.max) / 1_000,
                                        chapterTitle: "Zu lang")]

        #expect(FFmpegWrapper.convert(session: session, outputURL: output)
            == .rejected("Die Kapitelzeiten können nicht ausgegeben werden: Quelle.wav"))
        #expect(!session.isConverting)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("Beide Starteinstiege prüfen den Projektlink nochmals unter der Zielsperre", arguments: [false, true])
    @MainActor
    func startRejectsProjectLinkChangedWhileReservingOutput(asynchronous: Bool) async throws {
        let directory = try makeTestDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Original.wav")
        let replacement = directory.appendingPathComponent("Ersatz.wav")
        try writeSilentWAV(to: original)
        try writeSilentWAV(to: replacement, duration: 0.5)
        let link = directory.appendingPathComponent("Quelle.wav")
        let manager = FileManager.default
        try manager.createSymbolicLink(at: link, withDestinationURL: original)
        let session = ConversionSession(settings: AudioSettings())
        await session.importFiles([link], analyzeArtwork: false)
        try #require(session.audioFiles.count == 1)
        try await session.saveProjectAsync(to: directory.appendingPathComponent("Probe.hkproject"))
        try await session.verifyProjectSources()
        let output = directory.appendingPathComponent("Ausgabe.m4b")
        let plan = FFmpegWrapper.makeConversionPlan(files: session.audioFiles, outputURL: output, maxDurationHours: nil)
        func replaceLink() throws {
            try manager.removeItem(at: link)
            try manager.createSymbolicLink(at: link, withDestinationURL: replacement)
        }
        let start: ConversionStartResult
        if asynchronous {
            var checks = 0
            start = await FFmpegWrapper.startVerifiedConversionAsync(session: session, plan: plan) {
                checks += 1
                if checks == 2 {
                    do { try replaceLink() }
                    catch { Issue.record("Quelllink der Probe konnte nicht ersetzt werden: \(error)") }
                }
                return true
            }
        } else {
            start = FFmpegWrapper.convert(session: session, plan: plan, measureBookLoudness: nil,
                                          cachedProjectSourcesOnly: true) { actualPlan in
                try ConversionPlanner.validateConversionPlan(actualPlan)
                let leases = try OutputLeases.acquire(for: actualPlan.outputURLs)
                try replaceLink()
                return leases
            }
        }
        #expect(start == .rejected("Projektquellen fehlen oder wurden verändert."))
        #expect(session.projectSourceIssues.map(\.reason) == ["Verknüpfung wurde verändert"])
        #expect(!manager.fileExists(atPath: output.path))
        _ = try OutputLeases.acquire(for: [output])
    }

    @Test("Eine leere Liste ergibt mit und ohne Maximaldauer null Gruppen")
    func emptyListYieldsNoGroups() {
        // Früher war das asymmetrisch: ohne Maximaldauer kam `[[]]` zurück, mit
        // Maximaldauer `[]`. Der leere Plan lief damit in `validateConversionPlan`
        // in einen sachfremden Zielfehler („Die Zieldatei wurde seit der
        // Bestätigung verändert: /"). Beide Wege liefern jetzt `[]`, und der
        // Plan meldet dafür `noInputFiles`.
        #expect(ConversionPlanner.splitAudioFilesIfNeeded([], maxDurationHours: 10).isEmpty)
        #expect(ConversionPlanner.splitAudioFilesIfNeeded([], maxDurationHours: nil).isEmpty)
        // Ohne das Guard in `convert()` liefe die Gruppen-Schleife sonst null Mal
        // durch und der Lauf meldete Erfolg, ohne je eine Datei erzeugt zu haben.
        let empty = ConversionPlan(
            groups: [],
            outputURLs: [],
            outputSnapshots: [],
            outputDirectorySnapshots: [],
            inputSnapshots: [:]
        )
        #expect {
            try ConversionPlanner.validateConversionPlan(empty)
        } throws: { error in
            (error as? ConversionOutputError)?.errorDescription
                == "Keine Audiodateien zum Konvertieren vorhanden."
        }

        let file = file(1)
        let mixed = ConversionPlan(
            groups: [[file], []],
            outputURLs: [],
            outputSnapshots: [],
            outputDirectorySnapshots: [],
            inputSnapshots: [:]
        )
        #expect {
            try ConversionPlanner.validateConversionPlan(mixed)
        } throws: { error in
            (error as? ConversionOutputError)?.errorDescription
                == "Keine Audiodateien zum Konvertieren vorhanden."
        }
    }
}

@Suite("FFmpegWrapper – resolveOutputURL")
struct ResolveOutputURLTests {

    private let base = URL(fileURLWithPath: "/tmp/Buch.m4b")

    @Test("Ohne Split bleibt der Name unverändert")
    func singleGroupUnchanged() {
        #expect(ConversionPlanner.resolveOutputURL(base, groupIndex: 0, splitGroupsCount: 1) == base)
    }

    @Test("Mit Split werden -01, -02 angehängt")
    func splitGetsSuffix() {
        let first = ConversionPlanner.resolveOutputURL(base, groupIndex: 0, splitGroupsCount: 3)
        let second = ConversionPlanner.resolveOutputURL(base, groupIndex: 1, splitGroupsCount: 3)
        #expect(first.lastPathComponent == "Buch-01.m4b")
        #expect(second.lastPathComponent == "Buch-02.m4b")
    }

    @Test("Endung und Ordner bleiben erhalten")
    func keepsExtensionAndFolder() {
        let url = ConversionPlanner.resolveOutputURL(base, groupIndex: 0, splitGroupsCount: 2)
        #expect(url.pathExtension == "m4b")
        #expect(url.deletingLastPathComponent().path == "/tmp")
    }
}

@Suite("Quell- und Zielsnapshots")
struct ConversionTargetTests {
    @Test("Split-Ausgabe darf keine physische Eingabe ersetzen")
    func splitOutputCannotAliasInput() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Buch-01.m4b")
        try Data("Original".utf8).write(to: source)
        let files = [testAudioFile(source, duration: 3_600), testAudioFile(source, duration: 3_600)]
        let plan = FFmpegWrapper.makeConversionPlan(
            files: files,
            outputURL: directory.appendingPathComponent("Buch.m4b"),
            maxDurationHours: 1
        )

        #expect(throws: ConversionOutputError.self) {
            try ConversionPlanner.validateConversionPlan(plan)
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == "Original")
    }

    @Test("Hardlink-Ausgabe auf eine Eingabe wird erkannt")
    func hardLinkedOutputCannotAliasInput() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Quelle.m4b")
        let output = directory.appendingPathComponent("Ziel.m4b")
        try Data("Original".utf8).write(to: source)
        try FileManager.default.linkItem(at: source, to: output)
        let plan = FFmpegWrapper.makeConversionPlan(
            files: [testAudioFile(source)],
            outputURL: output,
            maxDurationHours: nil
        )

        #expect(throws: ConversionOutputError.self) {
            try ConversionPlanner.validateConversionPlan(plan)
        }
    }

    @Test("Eine nach der Planung geänderte Quelle wird abgewiesen")
    func changedInputIsRejected() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Quelle.wav")
        try Data("alt".utf8).write(to: source)
        let plan = FFmpegWrapper.makeConversionPlan(
            files: [testAudioFile(source)],
            outputURL: directory.appendingPathComponent("Ziel.m4b"),
            maxDurationHours: nil
        )
        try Data("anderer und längerer Inhalt".utf8).write(to: source)

        #expect(throws: ConversionOutputError.self) {
            try ConversionPlanner.validateConversionPlan(plan)
        }
    }

    @Test("Ein nach der Planung ersetzter Ausgabeordner wird abgewiesen")
    func changedOutputDirectoryIsRejected() throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Quelle.wav")
        let outputDirectory = root.appendingPathComponent("Ausgabe")
        let parkedDirectory = root.appendingPathComponent("Ausgabe-alt")
        try Data("audio".utf8).write(to: source)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: false
        )
        let plan = FFmpegWrapper.makeConversionPlan(
            files: [testAudioFile(source)],
            outputURL: outputDirectory.appendingPathComponent("Buch.m4b"),
            maxDurationHours: nil
        )
        try FileManager.default.moveItem(
            at: outputDirectory,
            to: parkedDirectory
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: false
        )

        #expect(throws: ConversionOutputError.self) {
            try ConversionPlanner.validateConversionPlan(plan)
        }
    }

    @Test("Gebrochener Ziel-Symlink verlangt eine Überschreibbestätigung")
    func brokenOutputSymlinkRequiresConfirmation() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Quelle.wav")
        let output = directory.appendingPathComponent("Buch.m4b")
        try Data("audio".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(
            at: output,
            withDestinationURL: directory.appendingPathComponent("fehlt.m4b")
        )
        let plan = FFmpegWrapper.makeConversionPlan(
            files: [testAudioFile(source)],
            outputURL: output,
            maxDurationHours: nil
        )

        #expect(plan.outputURLsRequiringOverwriteConfirmation == [output])
    }
}
