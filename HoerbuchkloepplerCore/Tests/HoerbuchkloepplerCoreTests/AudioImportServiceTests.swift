import Foundation
import AVFoundation
import Testing
@testable import HoerbuchkloepplerCore

private actor ImportWorkerProbe {
    private(set) var started = 0
    private(set) var active = 0
    private(set) var maximum = 0
    func enter() { started += 1; active += 1; maximum = max(maximum, active) }
    func leave() { active -= 1 }
}

private func importFixture(_ url: URL) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_000))
    buffer.frameLength = 2_000
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

@Suite("Importdienst – Bündelung und begrenzte Parallelität")
struct AudioImportServiceTests {
    @Test("1/2/4/8 Worker erhalten Eingangsreihenfolge", arguments: [1, 2, 4, 8])
    func boundedWorkers(limit: Int) async {
        let service = AudioImportService()
        service.workerLimit = limit
        let probe = ImportWorkerProbe()
        let result = await service.orderedMap(Array(0..<32), shouldCancel: { false }) { value in
            await probe.enter()
            try? await Task.sleep(for: .milliseconds(1 + (32 - value) % 7))
            await probe.leave()
            return value * value
        }
        #expect(result == (0..<32).map { $0 * $0 })
        #expect(await probe.maximum == limit)
        #expect(await probe.started == 32)
    }

    @Test("Abbruch beginnt keine weiteren Quellen und verwirft Teilergebnisse")
    func cancellationStopsScheduling() async {
        let service = AudioImportService()
        let probe = ImportWorkerProbe()
        let task = Task {
            await service.orderedMap(Array(0..<100), shouldCancel: { false }) { value in
                await probe.enter()
                try? await Task.sleep(for: .seconds(5))
                await probe.leave()
                return value
            }
        }
        while await probe.started < 4 { await Task.yield() }
        task.cancel()
        #expect(await task.value == nil)
        #expect(await probe.started == 4)
        #expect(await probe.active == 0)
    }

    @Test("Ein Asset-Aufruf pro Quelle, keine Bilddaten ohne Bedarf")
    func combinedAnalysisAndLazyArtwork() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("01 Sprache.wav")
        try importFixture(url)
        let service = AudioImportService()
        guard case .success(let analysis) = await service.analyze(FoundFile(source: url, resolved: url)) else {
            Issue.record("Echte WAV-Datei konnte nicht analysiert werden")
            return
        }
        #expect(abs(analysis.file.duration - 0.25) < 0.001)
        #expect(analysis.file.chapterTitle == "01 Sprache")
        #expect(service.metrics.sourceAnalyses == 1)
        #expect(service.metrics.assetLoadRequests == 1)
        #expect(service.metrics.artworkDataRequests == 0)
        #expect(await service.artwork(at: url) == nil)
        #expect(service.metrics.assetLoadRequests == 1)
        #expect(service.metrics.artworkDataRequests == 0)

        // Ein Austausch am selben Pfad darf den alten Metadaten-Snapshot nicht
        // für eine spätere Coversuche legitimieren.
        let replacement = folder.appendingPathComponent("replacement.wav")
        try importFixture(replacement)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacement, to: url)
        #expect(!analysis.isCurrent())
        #expect(await service.artwork(from: analysis) == nil)
    }

    @Test("Zusätzliche Buchtags werden ohne Verwechslung von Reihe und Band gelesen")
    func additionalBookMetadata() async {
        let values = [("narrator", "Ada Beispiel"), ("series_part", "3"), ("language", "deu")]
        let items = values.map { key, value in
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = key as NSString
            item.value = value as NSString
            return item as AVMetadataItem
        }
        let result = await AudioImportService.bookMetadata(from: items)
        #expect(result == ["narrator": "Ada Beispiel", "volume_number": "3", "language": "deu"])
        #expect(result["series"] == nil)
    }

    @Test("ID3-Frames liefern Sprecher, Reihe und Bandnummer ohne Gesamtzahl")
    func id3BookMetadata() async {
        func frame(_ key: String, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.keySpace = .id3
            item.key = key as NSString
            item.value = value as NSString
            return item
        }
        let result = await AudioImportService.bookMetadata(from: [
            frame("TCOM", "Ada Beispiel"), frame("TIT1", "Testreihe"), frame("TPOS", "2/5")
        ])
        #expect(result == ["narrator": "Ada Beispiel", "series": "Testreihe", "volume_number": "2"])
    }

    @Test("Native MP4-Tags liefern Sprecher, Reihe und binäre Bandnummer")
    func nativeBookMetadata() async {
        let composer = AVMutableMetadataItem()
        composer.identifier = AVMetadataIdentifier(rawValue: "itsk/%A9wrt")
        composer.value = "Ada Beispiel" as NSString
        let grouping = AVMutableMetadataItem()
        grouping.identifier = AVMetadataIdentifier(rawValue: "itsk/%A9grp")
        grouping.value = "Testreihe" as NSString
        let disc = AVMutableMetadataItem()
        disc.identifier = AVMetadataIdentifier(rawValue: "itsk/disk")
        disc.value = Data([0, 0, 0, 3, 0, 0, 0, 0]) as NSData
        let result = await AudioImportService.bookMetadata(from: [composer, grouping, disc])
        #expect(result == ["narrator": "Ada Beispiel", "series": "Testreihe", "volume_number": "3"])
    }

    @Test("Ordnerscan sammelt alle Fehler trotz gültiger Zwischenquellen")
    @MainActor
    func completeFailureDiagnostics() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("broken".utf8).write(to: folder.appendingPathComponent("01-broken.wav"))
        try importFixture(folder.appendingPathComponent("02-valid.wav"))
        try Data("also broken".utf8).write(to: folder.appendingPathComponent("03-broken.wav"))
        try importFixture(folder.appendingPathComponent("04-valid.wav"))
        let session = ConversionSession()
        let result = await session.scanFolder(folder, analyzeArtwork: false)
        #expect(result.audioFiles.map(\.chapterTitle) == ["02-valid", "04-valid"])
        #expect(result.failures.map { $0.sourceURL.lastPathComponent } == ["01-broken.wav", "03-broken.wav"])
        #expect(session.importService.metrics.sourceAnalyses == 4)
        #expect(session.importService.metrics.assetLoadRequests == 4)
        #expect(session.importService.metrics.artworkDataRequests == 0)
    }
}
