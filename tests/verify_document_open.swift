import Foundation
import AVFoundation
import HoerbuchkloepplerCore

@MainActor
private final class DelayedImportProbe {
    var releaseFirst = false
    var batches: [[URL]] = []
}

@main
struct DocumentOpenCheck {
    @MainActor
    static func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { fatalError("Dokumentöffnung: Endzustand nicht erreicht") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    static func main() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("HKDocumentOpen-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2000)!
        buffer.frameLength = 2000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 2000)
        let urls = (0..<3).map { base.appendingPathComponent("Quelle-\($0).wav") }
        for url in urls {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        let opener = DocumentOpenCoordinator()
        var stops = 0
        opener.receive(urls[0], session: session, beforeOpening: { stops += 1 })
        opener.receive(urls[1], session: session, beforeOpening: { stops += 1 })
        try await waitFor { session.audioFiles.count == 2 && !session.isImporting }
        precondition(stops == 1 && Set(session.audioFiles.map(\.url)) == Set(urls.prefix(2)))
        print("PASS: zwei System-URL-Ereignisse als vollständiger gemeinsamer Audioimport")

        let delayedSession = ConversionSession(settings: AudioSettings())
        delayedSession.logSink = { _ in }
        let delayedProbe = DelayedImportProbe()
        let delayedOpener = DocumentOpenCoordinator { urls, session in
            delayedProbe.batches.append(urls)
            if delayedProbe.batches.count == 1 {
                _ = session.beginImport(expectedItemCount: 1)
                while !delayedProbe.releaseFirst { try? await Task.sleep(for: .milliseconds(10)) }
                session.cancelImport()
            }
            await ImportCoordinator.importURLs(urls, session: session)
        }
        delayedOpener.receive(urls[0], session: delayedSession, beforeOpening: {})
        try await waitFor { delayedSession.isImporting }
        delayedOpener.receive(urls[1], session: delayedSession, beforeOpening: {})
        try await Task.sleep(for: .milliseconds(150))
        precondition(delayedOpener.errorMessage == nil && delayedProbe.batches.count == 1)
        delayedProbe.releaseFirst = true
        try await waitFor { delayedSession.audioFiles.count == 2 && !delayedSession.isImporting }
        precondition(delayedProbe.batches == [[urls[0]], [urls[1]]])
        print("PASS: verspätete System-URL bleibt während eigenem Import erhalten und wird danach importiert")

        let projectURL = base.appendingPathComponent("Projekt.hkproject")
        session.title = "Gespeichertes Projekt"
        try await session.saveProjectAsync(to: projectURL)
        let emptySession = ConversionSession(settings: AudioSettings())
        emptySession.logSink = { _ in }
        let emptyOpener = DocumentOpenCoordinator()
        emptyOpener.receive(projectURL, session: emptySession, beforeOpening: {})
        try await waitFor { emptySession.title == "Gespeichertes Projekt" }
        precondition(emptyOpener.projectToConfirm == nil && emptySession.audioFiles.count == 2)
        print("PASS: Projekt öffnet in leerem Fenster direkt und vollständig")
        session.title = "Nicht gespeicherter Stand"
        let original = session.audioFiles
        opener.receive(projectURL, session: session, beforeOpening: {})
        try await waitFor { opener.projectToConfirm != nil }
        precondition(session.title == "Nicht gespeicherter Stand" && session.audioFiles == original)
        opener.cancelProject()
        precondition(session.title == "Nicht gespeicherter Stand" && session.audioFiles == original)
        print("PASS: Projektöffnung fragt vor Ersetzen; Abbrechen erhält bestehenden Stand")

        opener.receive(projectURL, session: session, beforeOpening: {})
        try await waitFor { opener.projectToConfirm != nil }
        // SwiftUI kann die Präsentations-Bindung vor dem asynchronen Button-Task
        // zurücksetzen. Die bestätigte URL muss davon unabhängig erhalten sein.
        let confirmed = opener.projectToConfirm!
        opener.cancelProject()
        await opener.confirmProject(confirmed, session: session, beforeOpening: {})
        precondition(session.title == "Gespeichertes Projekt" && session.audioFiles.count == 2)
        print("PASS: bestätigtes Projekt öffnet auch nach Auflösen der Alert-Bindung")

        let broken = base.appendingPathComponent("Defekt.hkproject")
        try Data("kein Projekt".utf8).write(to: broken)
        await opener.confirmProject(broken, session: session, beforeOpening: {})
        precondition(opener.errorMessage != nil && session.title == "Gespeichertes Projekt")
        opener.errorMessage = nil
        opener.receive(projectURL, session: session, beforeOpening: {})
        opener.receive(urls[2], session: session, beforeOpening: {})
        try await waitFor { opener.errorMessage != nil }
        precondition(session.audioFiles.count == 2 && opener.projectToConfirm == nil)
        print("PASS: defektes Projekt und gemischte Projektauswahl erhalten Bestand")

        opener.errorMessage = nil
        _ = session.beginImport(expectedItemCount: 1)
        opener.receive(urls[2], session: session, beforeOpening: {})
        try await waitFor { opener.errorMessage != nil }
        precondition(session.isImporting && session.audioFiles.count == 2)
        session.cancelImport()
        opener.errorMessage = nil
        opener.receive(URL(string: "https://example.invalid/Quelle.wav")!, session: session, beforeOpening: {})
        precondition(opener.errorMessage != nil && session.audioFiles.count == 2)
        print("PASS: laufender Import und fremdes URL-Schema werden ohne Zustandsverlust abgewiesen")
    }
}
