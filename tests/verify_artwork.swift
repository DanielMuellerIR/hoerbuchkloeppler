import AppKit
import AVFoundation
import Darwin
import HoerbuchkloepplerCore

@main struct VerifyArtwork {
    @MainActor static func main() async throws {
        let mode = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        if mode == "baseline-preview" {
            let image = NSImage(data: try Data(contentsOf: root.appendingPathComponent("large.png")))!
            let result = NSImage(size: NSSize(width: 2_000, height: 2_000 * image.size.height / image.size.width))
            result.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: result.size), from: .zero, operation: .copy, fraction: 1)
            result.unlockFocus()
            print("baseline preview", result.size)
        } else if mode == "baseline-embedded" {
            let metadata = try await AVURLAsset(url: root.appendingPathComponent("oversized.mp3")).load(.metadata)
            for item in metadata where item.commonKey == .commonKeyArtwork {
                let data = try await item.load(.dataValue)
                print("baseline loaded bytes", data?.count ?? 0)
            }
        } else if mode == "embedded-limit" {
            let oversized = await AudioFile.extractEmbeddedArtwork(from: root.appendingPathComponent("oversized.mp3"))
            precondition(oversized == nil)
            print("oversized embedded rejected")
        } else {
            let session = ConversionSession(settings: AudioSettings())
            session.logSink = { _ in }
            precondition(session.selectCover(url: root.appendingPathComponent("large.png")))
            let size = session.coverImage!.size
            precondition(size.width == 2_000 && size.height <= 1_334)
            let original = try Data(contentsOf: root.appendingPathComponent("large.png"))
            precondition(session.embeddedCoverData == original)
            for name in ["oversized.png", "invalid.png"] {
                precondition(!session.selectCover(url: root.appendingPathComponent(name)))
                precondition(session.coverImage!.size == size)
            }
            for name in ["small.mp3", "small.m4a", "large.mp3", "later-valid.mp3"] {
                let data = await AudioFile.extractEmbeddedArtwork(from: root.appendingPathComponent(name))
                let expected = try Data(contentsOf: root.appendingPathComponent(name == "large.mp3" ? "large.png" : "small.png"))
                precondition(data == expected, "Cover fehlt oder Originalbytes verändert: \(name)")
            }
            let invalid = await AudioFile.extractEmbeddedArtwork(from: root.appendingPathComponent("invalid.mp3"))
            precondition(invalid == nil)
            print("OK: große Vorschau begrenzt; Originalbytes erhalten; MP3/M4A/späteres Cover; ungültige und übergroße Auswahl erhält Bestand")
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("maximum RSS bytes", usage.ru_maxrss)
        getrusage(RUSAGE_CHILDREN, &usage)
        print("maximum child RSS bytes", usage.ru_maxrss)
    }
}
