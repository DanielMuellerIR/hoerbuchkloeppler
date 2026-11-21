import Foundation
import Testing
@testable import HoerbuchkloepplerCore

@Suite("Covergröße und Originalbytes")
struct ArtworkResourceTests {
    @Test("Große Bilder bekommen eine begrenzte Vorschau, defekte Bilder ersetzen kein Cover")
    @MainActor
    func extractsAndPreparesBoundedArtwork() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = try #require(ToolLocator.binaryURL(name: "ffmpeg"))
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let generator = repository.appendingPathComponent("tests/generate_artwork_fixtures.py")
        let generated = await Task.detached {
            ProcessRunner.capture(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["python3", generator.path, directory.path, ffmpeg.path],
                timeout: 30
            )
        }.value
        guard case .completed(let status, let diagnostics) = generated, status == 0 else {
            Issue.record("Cover-Testdateien konnten nicht erzeugt werden: \(generated)")
            return
        }
        #expect(diagnostics.isEmpty)

        let session = ConversionSession(settings: AudioSettings())
        let large = directory.appendingPathComponent("large.png")
        try #require(session.selectCover(url: large))
        let preview = try #require(session.coverImage)
        #expect(preview.size.width == 2_000)
        #expect(preview.size.height <= 1_334)
        let largeBytes = try Data(contentsOf: large)
        #expect(session.embeddedCoverData == largeBytes)
        for name in ["oversized.png", "invalid.png"] {
            #expect(!session.selectCover(url: directory.appendingPathComponent(name)))
            #expect(session.coverImage === preview)
        }

        let smallBytes = try Data(contentsOf: directory.appendingPathComponent("small.png"))
        for name in ["small.mp3", "small.m4a", "large.mp3", "later-valid.mp3", "oversized-first.mp3"] {
            let data = await AudioFile.extractEmbeddedArtwork(from: directory.appendingPathComponent(name))
            let expected = name == "large.mp3" ? largeBytes : smallBytes
            #expect(data == expected, "Cover-Originalbytes fehlen: \(name)")
        }
        for name in ["invalid.mp3", "oversized.mp3"] {
            let data = await AudioFile.extractEmbeddedArtwork(from: directory.appendingPathComponent(name))
            #expect(data == nil, "Unzulässiges Cover wurde übernommen: \(name)")
        }
    }
}
