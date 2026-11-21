import Foundation
import AppKit
import AVFoundation
import HoerbuchkloepplerCore
import Testing
@testable import HoerbuchkloepplerAppSupport

// Foundation ruft den Ladehandler außerhalb des Main Actors auf; alle geteilten
// Felder und der einmalige Übergang zur späten Antwort sind über den Lock gebunden.
private final class ProviderGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (NSURL?, Error?) -> Void)?
    private var releasedURL: URL?
    private var cancellations = 0

    var cancellationCount: Int { lock.withLock { cancellations } }
    var hasPendingLoad: Bool { lock.withLock { completion != nil } }

    func load(_ completion: @escaping @Sendable (NSURL?, Error?) -> Void) -> Progress {
        let url: URL? = lock.withLock {
            if let releasedURL { return releasedURL }
            self.completion = completion
            return nil as URL?
        }
        if let url { completion(url as NSURL, nil) }
        let progress = Progress(totalUnitCount: 1)
        progress.cancellationHandler = { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.cancellations += 1 }
        }
        return progress
    }

    func release(_ url: URL) {
        let callback = lock.withLock {
            releasedURL = url
            let callback = completion
            completion = nil
            return callback
        }
        callback?(url as NSURL, nil)
    }

    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerObject(ofClass: NSURL.self, visibility: .all) { [self] callback in
            load(callback)
        }
        precondition(provider.canLoadObject(ofClass: URL.self), "Provider muss als URL ladbar sein")
        return provider
    }
}

private final class CoverPreparationGate: Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)

    func prepare(_ url: URL) -> ConversionSession.PreparedCover? {
        precondition(!Thread.isMainThread, "Cover-Datei wurde auf dem Main Thread geladen")
        let cover = ConversionSession.PreparedCover(url: url)
        started.signal()
        _ = release.wait(timeout: .now() + 5)
        finished.signal()
        return cover
    }
}

extension AppSupportTests {
    @MainActor func waitForImportState(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw FixtureFailure("Providerprüfung: Endzustand nicht erreicht") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Provider-Import, Cover-Auswahl und Werkzeugzustand")
    func providerImportAndCoverDrop() async throws {
        let session = ConversionSession(settings: AudioSettings(importWorkerLimit: 2))
        session.logSink = { _ in }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("GUIImportTest-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        try verifyToolStatus()
        try await verifyCoverDrop(in: base)
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2000)!
        buffer.frameLength = 2000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 2000)
        for index in 0..<16 {
            let file = try AVAudioFile(forWriting: base.appendingPathComponent("\(index).wav"), settings: format.settings)
            try file.write(from: buffer)
        }
        let urls = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil).filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path }
        let providers = Array(urls.prefix(8)).map { NSItemProvider(object: $0 as NSURL) }
        ImportCoordinator.importProviders(providers, session: session)
        for _ in 0..<1000 {
            if !session.isImporting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard session.audioFiles.count == 8, !session.isImporting,
              session.importCompletedItems == session.importTotalItems else {
            throw FixtureFailure("Providerimport unvollständig: \(session.audioFiles.count), \(session.importCompletedItems)/\(session.importTotalItems)")
        }
        let saved = session.audioFiles
        ImportCoordinator.importProviders(Array(urls.suffix(8)).map { NSItemProvider(object: $0 as NSURL) }, session: session)
        session.cancelImport()
        try await Task.sleep(for: .milliseconds(200))
        guard session.audioFiles == saved, !session.isImporting else { throw FixtureFailure("Verspäteter Provider änderte Buch") }
        print("PASS: acht echte Provider, vollständiger Fortschritt, Abbruch und erhaltenes Buch")

        session.title = "Vorhandenes Hörbuch"
        let gate = ProviderGate()
        let hanging = gate.provider()
        let batch = [NSItemProvider(object: urls[8] as NSURL), hanging]
        var timeouts = 0
        var retry: [NSItemProvider] = []
        ImportCoordinator.importProviders(batch, session: session, timeout: .milliseconds(50), onTimeout: { providers in
            timeouts += 1
            retry = providers
        })
        try await waitForImportState { timeouts == 1 && !session.isImporting }
        try #require(session.audioFiles == saved && session.title == "Vorhandenes Hörbuch" && retry.count == 2)
        try await waitForImportState { gate.cancellationCount > 0 }
        gate.release(urls[9])
        try await Task.sleep(for: .milliseconds(100))
        try #require(session.audioFiles == saved && timeouts == 1 && !session.isImporting)
        print("PASS: hängender Provider läuft ins Zeitlimit; Teilbatch verworfen, Progress abgebrochen, spätere Antwort ignoriert")

        ImportCoordinator.importProviders(retry, session: session, timeout: .seconds(2), onTimeout: { _ in timeouts += 1 })
        try await waitForImportState { session.audioFiles.count == 10 && !session.isImporting }
        try #require(timeouts == 1 && session.title == "Vorhandenes Hörbuch")
        print("PASS: dieselben Provider lassen sich nach Freigabe erfolgreich wiederholen")

        let current = session.audioFiles
        let cancelled = ProviderGate()
        ImportCoordinator.importProviders([cancelled.provider()], session: session, timeout: .milliseconds(100), onTimeout: { _ in timeouts += 1 })
        try await Task.sleep(for: .milliseconds(20))
        session.cancelImport()
        try await Task.sleep(for: .milliseconds(150))
        cancelled.release(urls[10])
        try await Task.sleep(for: .milliseconds(50))
        try #require(timeouts == 1 && session.audioFiles == current && !session.isImporting)
        print("PASS: Benutzerabbruch vor Frist erzeugt weder Timeoutdialog noch verspätete Kapitel")

        let replaced = ProviderGate()
        ImportCoordinator.importProviders([replaced.provider()], session: session, timeout: .milliseconds(100), onTimeout: { _ in timeouts += 1 })
        try await Task.sleep(for: .milliseconds(20))
        ImportCoordinator.importProviders([NSItemProvider(object: urls[10] as NSURL)], session: session)
        try await waitForImportState { session.audioFiles.count == 11 && !session.isImporting }
        try await Task.sleep(for: .milliseconds(150))
        replaced.release(urls[11])
        try await Task.sleep(for: .milliseconds(50))
        try #require(timeouts == 1 && session.audioFiles.count == 11)
        print("PASS: neuer Import entwertet alten Timer und alte Provider-Antwort")

        if ProcessInfo.processInfo.environment["HOERBUCHKLOEPPLER_VERIFY_PROVIDER_TIMEOUT"] == "1" {
            let never = ProviderGate()
            let prior = session.audioFiles
            var defaultTimeout = false
            let start = ContinuousClock.now
            ImportCoordinator.importProviders([never.provider()], session: session, onTimeout: { _ in defaultTimeout = true })
            let deadline = start + .seconds(70)
            while !defaultTimeout {
                try #require(ContinuousClock.now < deadline, "Standardfrist überschritten")
                try await Task.sleep(for: .milliseconds(50))
            }
            let elapsed = start.duration(to: .now)
            try #require(elapsed >= .seconds(60) && elapsed < .seconds(65))
            try #require(!session.isImporting && session.audioFiles == prior)
            print("PASS: tatsächliche Standardfrist 60 Sekunden, gemessen \(elapsed)")
        }
    }

    private func verifyToolStatus() throws {
        let available = ToolStatus.Availability.available(version: "8.1")
        try #require(ToolStatus().exportAvailability == .checking)
        try #require(ToolStatus(ffmpeg: .unavailable).exportAvailability == .checking)
        try #require(ToolStatus(mediaInfo: .unavailable).exportAvailability == .checking)
        try #require(ToolStatus(ffmpeg: available, mediaInfo: available).exportAvailability == .available)
        let unavailable = ToolStatus(ffmpeg: available, mediaInfo: .unavailable)
        guard case .unavailable(let message) = unavailable.exportAvailability else {
            throw FixtureFailure("Abgeschlossene Prüfung ohne MediaInfo muss den Export blockieren")
        }
        try #require(message.contains("Nicht verfügbar: MediaInfo.") && message.contains("bringt beide Programme mit"))
        print("PASS: laufende Werkzeugprüfung bleibt ohne Fehler, erst das abgeschlossene Ergebnis gibt den Export frei oder meldet fehlende Verfügbarkeit")
    }

    @MainActor private func verifyCoverDrop(in directory: URL) async throws {
        guard let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgmMAAAAEkAJHtzFYFAAAAAElFTkSuQmCC") else {
            throw FixtureFailure("PNG-Testbild konnte nicht dekodiert werden")
        }
        let original = directory.appendingPathComponent("vorhanden.png")
        let new = directory.appendingPathComponent("ausgewählt.png")
        let invalid = directory.appendingPathComponent("unlesbar.png")
        try png.write(to: original)
        try png.write(to: new)
        try Data("Kein Bild".utf8).write(to: invalid)
        let session = ConversionSession(settings: AudioSettings())
        let coordinator = CoverDropCoordinator()
        try #require(session.selectCover(url: original))

        let hanging = ProviderGate()
        coordinator.load(hanging.provider(), session: session, timeout: .milliseconds(100))
        try await waitForImportState { coordinator.errorMessage?.contains("nicht rechtzeitig") == true && hanging.cancellationCount > 0 }
        hanging.release(new)
        try await Task.sleep(for: .milliseconds(50))
        try #require(session.coverPath == original.path)
        print("PASS: Cover-Timeout bricht den Provider ab und erhält das vorhandene Cover nach verspäteter Antwort")

        let superseded = ProviderGate()
        coordinator.load(superseded.provider(), session: session)
        try await waitForImportState { superseded.hasPendingLoad }
        coordinator.load(NSItemProvider(object: new as NSURL), session: session)
        try await waitForImportState { session.coverPath == new.path && superseded.cancellationCount > 0 }
        superseded.release(original)
        try await Task.sleep(for: .milliseconds(50))
        try #require(session.coverPath == new.path && coordinator.errorMessage == nil)
        print("PASS: Ein zweiter Cover-Drop führt die Auswahl aus und entwertet den ersten Provider")

        let removed = ProviderGate()
        coordinator.load(removed.provider(), session: session)
        try await waitForImportState { removed.hasPendingLoad }
        session.removeCover()
        try await waitForImportState { removed.cancellationCount > 0 }
        removed.release(original)
        try await Task.sleep(for: .milliseconds(50))
        try #require(session.isCoverSuppressed && session.coverImage == nil && coordinator.errorMessage == nil)
        print("PASS: Ein bewusst entferntes Cover bleibt auch nach einer späten Provider-Antwort entfernt")

        coordinator.load(NSItemProvider(object: invalid as NSURL), session: session)
        try await waitForImportState { coordinator.errorMessage?.contains(invalid.lastPathComponent) == true }
        try #require(session.isCoverSuppressed && session.coverImage == nil)
        print("PASS: Ungültiger Cover-Drop meldet die Datei und erhält die vorangegangene Auswahl")

        let embeddedDirectory = directory.appendingPathComponent("embedded", isDirectory: true)
        let looseDirectory = directory.appendingPathComponent("loose", isDirectory: true)
        for folder in [embeddedDirectory, looseDirectory] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let looseCover = looseDirectory.appendingPathComponent("Cover.png")
        try png.write(to: looseCover)
        try writeTestAudio(to: embeddedDirectory.appendingPathComponent("Kapitel.m4a"), cover: original)
        try writeTestAudio(to: looseDirectory.appendingPathComponent("Kapitel.wav"))

        for folder in [embeddedDirectory, looseDirectory] {
            session.resetSession()
            let manual = ProviderGate()
            coordinator.load(manual.provider(), session: session)
            try await waitForImportState { manual.hasPendingLoad }
            await session.importURLs([folder])
            try #require(session.audioFiles.count == 1 && session.coverImage != nil)
            if folder == looseDirectory, let coverPath = session.coverPath {
                try #require(coverPath.hasSuffix("/loose/Cover.png"))
            } else {
                try #require(folder == embeddedDirectory && session.coverPath == nil)
            }
            manual.release(new)
            try await waitForImportState { session.coverPath == new.path }
            try #require(manual.cancellationCount == 0 && coordinator.errorMessage == nil)
        }
        print("PASS: Manueller Drop gewinnt gegen inzwischen übernommenes eingebettetes und loses Ordnercover")

        let reselected = ProviderGate()
        coordinator.load(reselected.provider(), session: session)
        try await waitForImportState { reselected.hasPendingLoad }
        try #require(session.selectCover(url: new))
        try await waitForImportState { reselected.cancellationCount > 0 }
        reselected.release(original)
        try await Task.sleep(for: .milliseconds(50))
        try #require(session.coverPath == new.path && coordinator.errorMessage == nil)
        print("PASS: Auch die erneute Auswahl desselben Covers überholt einen offenen Drop")

        let beforeReset = ProviderGate()
        coordinator.load(beforeReset.provider(), session: session)
        try await waitForImportState { beforeReset.hasPendingLoad }
        session.resetSession()
        try await waitForImportState { beforeReset.cancellationCount > 0 }
        beforeReset.release(original)
        try await Task.sleep(for: .milliseconds(50))
        try #require(session.coverImage == nil && coordinator.errorMessage == nil)
        print("PASS: Nach dem Zurücksetzen des Buchs bleibt ein verspäteter Cover-Drop wirkungslos")

        let slowPreparation = CoverPreparationGate()
        let timedDrop = CoverDropCoordinator(prepareCover: slowPreparation.prepare)
        try #require(session.selectCover(url: original))
        timedDrop.load(NSItemProvider(object: new as NSURL), session: session, timeout: .milliseconds(500))
        try await waitForImportState { slowPreparation.started.wait(timeout: .now()) == .success }
        try await waitForImportState { timedDrop.errorMessage?.contains("nicht rechtzeitig") == true }
        slowPreparation.release.signal()
        try await waitForImportState { slowPreparation.finished.wait(timeout: .now()) == .success }
        try await Task.sleep(for: .milliseconds(50))
        try #require(session.coverPath == original.path)
        print("PASS: Cover-Datei wird im Hintergrund geladen; Frist läuft bis zur fertigen Vorschau und überholte Bytes werden verworfen")
    }

    private func writeTestAudio(to url: URL, cover: URL? = nil) throws {
        guard let ffmpeg = FFmpegWrapper.getBinaryURL(name: "ffmpeg") else {
            throw FixtureFailure("Die Cover-Fixture benötigt das gebündelte FFmpeg")
        }
        var arguments = ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=duration=0.3"]
        if let cover {
            arguments += [
                "-i", cover.path, "-map", "0:a", "-map", "1:v", "-c:a", "aac",
                "-c:v", "copy", "-disposition:v", "attached_pic"
            ]
        }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments + [url.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "Cover-Fixture konnte nicht erzeugt werden")
    }
}
