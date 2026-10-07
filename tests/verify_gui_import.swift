import Foundation
import AppKit
import AVFoundation
import HoerbuchkloepplerCore

// Foundation ruft den Ladehandler außerhalb des Main Actors auf; alle geteilten
// Felder und der einmalige Übergang zur späten Antwort sind über den Lock gebunden.
private final class ProviderGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Data?, Error?) -> Void)?
    private var releasedURL: URL?
    private var cancellations = 0

    var cancellationCount: Int { lock.withLock { cancellations } }

    func load(_ completion: @escaping @Sendable (Data?, Error?) -> Void) -> Progress {
        let url: URL? = lock.withLock {
            if let releasedURL { return releasedURL }
            self.completion = completion
            return nil as URL?
        }
        if let url { completion(Data(url.absoluteString.utf8), nil) }
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
        callback?(Data(url.absoluteString.utf8), nil)
    }

    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: "public.file-url", visibility: .all) { [self] callback in
            load(callback)
        }
        return provider
    }
}

@main struct ImportCheck {
    @MainActor static func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { fatalError("Providerprüfung: Endzustand nicht erreicht") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor static func main() async throws {
        let session = ConversionSession(settings: AudioSettings(importWorkerLimit: 2))
        session.logSink = { _ in }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("GUIImportTest-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
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
            fatalError("Providerimport unvollständig: \(session.audioFiles.count), \(session.importCompletedItems)/\(session.importTotalItems)")
        }
        let saved = session.audioFiles
        ImportCoordinator.importProviders(Array(urls.suffix(8)).map { NSItemProvider(object: $0 as NSURL) }, session: session)
        session.cancelImport()
        try await Task.sleep(for: .milliseconds(200))
        guard session.audioFiles == saved, !session.isImporting else { fatalError("Verspäteter Provider änderte Buch") }
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
        try await waitFor { timeouts == 1 && !session.isImporting }
        precondition(session.audioFiles == saved && session.title == "Vorhandenes Hörbuch" && retry.count == 2)
        try await waitFor { gate.cancellationCount > 0 }
        gate.release(urls[9])
        try await Task.sleep(for: .milliseconds(100))
        precondition(session.audioFiles == saved && timeouts == 1 && !session.isImporting)
        print("PASS: hängender Provider läuft ins Zeitlimit; Teilbatch verworfen, Progress abgebrochen, spätere Antwort ignoriert")

        ImportCoordinator.importProviders(retry, session: session, timeout: .seconds(2), onTimeout: { _ in timeouts += 1 })
        try await waitFor { session.audioFiles.count == 10 && !session.isImporting }
        precondition(timeouts == 1 && session.title == "Vorhandenes Hörbuch")
        print("PASS: dieselben Provider lassen sich nach Freigabe erfolgreich wiederholen")

        let current = session.audioFiles
        let cancelled = ProviderGate()
        ImportCoordinator.importProviders([cancelled.provider()], session: session, timeout: .milliseconds(100), onTimeout: { _ in timeouts += 1 })
        try await Task.sleep(for: .milliseconds(20))
        session.cancelImport()
        try await Task.sleep(for: .milliseconds(150))
        cancelled.release(urls[10])
        try await Task.sleep(for: .milliseconds(50))
        precondition(timeouts == 1 && session.audioFiles == current && !session.isImporting)
        print("PASS: Benutzerabbruch vor Frist erzeugt weder Timeoutdialog noch verspätete Kapitel")

        let replaced = ProviderGate()
        ImportCoordinator.importProviders([replaced.provider()], session: session, timeout: .milliseconds(100), onTimeout: { _ in timeouts += 1 })
        try await Task.sleep(for: .milliseconds(20))
        ImportCoordinator.importProviders([NSItemProvider(object: urls[10] as NSURL)], session: session)
        try await waitFor { session.audioFiles.count == 11 && !session.isImporting }
        try await Task.sleep(for: .milliseconds(150))
        replaced.release(urls[11])
        try await Task.sleep(for: .milliseconds(50))
        precondition(timeouts == 1 && session.audioFiles.count == 11)
        print("PASS: neuer Import entwertet alten Timer und alte Provider-Antwort")

        if ProcessInfo.processInfo.arguments.contains("--default-timeout") {
            let never = ProviderGate()
            let prior = session.audioFiles
            var defaultTimeout = false
            let start = ContinuousClock.now
            ImportCoordinator.importProviders([never.provider()], session: session, onTimeout: { _ in defaultTimeout = true })
            let deadline = start + .seconds(70)
            while !defaultTimeout {
                precondition(ContinuousClock.now < deadline, "Standardfrist überschritten")
                try await Task.sleep(for: .milliseconds(50))
            }
            let elapsed = start.duration(to: .now)
            precondition(elapsed >= .seconds(60) && elapsed < .seconds(65))
            precondition(!session.isImporting && session.audioFiles == prior)
            print("PASS: tatsächliche Standardfrist 60 Sekunden, gemessen \(elapsed)")
        }
    }
}
