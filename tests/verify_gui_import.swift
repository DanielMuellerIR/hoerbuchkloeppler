import Foundation
import AppKit
import AVFoundation
import HoerbuchkloepplerCore

@main struct ImportCheck {
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
        print("GUI-Importkoordination: acht Provider, Fortschritt und Abbruch geprüft")
    }
}
