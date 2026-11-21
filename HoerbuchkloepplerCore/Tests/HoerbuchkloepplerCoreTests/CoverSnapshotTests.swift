import Foundation
import Testing
@testable import HoerbuchkloepplerCore
import Darwin

@Suite("Dateigebundener Cover-Snapshot")
struct CoverSnapshotTests {
    @Test("Coverdaten bleiben nach Austausch der Quelldatei unverändert")
    func coverIsSnapshotted() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cover = directory.appendingPathComponent("cover.jpg")
        let original = try onePixelPNGData()
        try original.write(to: cover)
        let snapshot = try #require(FFmpegWrapper.loadCoverSnapshot(at: cover))
        try Data("nachher".utf8).write(to: cover)

        #expect(snapshot == original)
    }

    @Test("Cover-Lader weist FIFO, Übergröße und ungültige Bilddaten ab")
    func coverSnapshotRejectsUnsafeInputs() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("cover-fifo.jpg")
        let oversized = directory.appendingPathComponent("cover-gross.jpg")
        let invalid = directory.appendingPathComponent("cover-ungueltig.jpg")

        let fifoResult = fifo.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.mkfifo($0, mode_t(0o600)) } ?? -1
        }
        #expect(fifoResult == 0)
        let descriptor = oversized.withUnsafeFileSystemRepresentation { path in
            path.map {
                Darwin.open($0, O_CREAT | O_WRONLY | O_CLOEXEC, mode_t(0o600))
            } ?? -1
        }
        #expect(descriptor >= 0)
        if descriptor >= 0 {
            #expect(Darwin.ftruncate(
                descriptor,
                off_t(FFmpegWrapper.maximumCoverByteCount + 1)
            ) == 0)
            _ = Darwin.close(descriptor)
        }
        try Data("kein Bild".utf8).write(to: invalid)

        let start = Date()
        #expect(FFmpegWrapper.loadCoverSnapshot(at: fifo) == nil)
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(FFmpegWrapper.loadCoverSnapshot(at: oversized) == nil)
        #expect(FFmpegWrapper.loadCoverSnapshot(at: invalid) == nil)
    }

    @Test("Cover-Snapshot verlangt den beim Klick erfassten Dateieintrag")
    func coverSnapshotRejectsReplacementAfterPlanning() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cover = directory.appendingPathComponent("cover.png")
        let data = try onePixelPNGData()
        try data.write(to: cover)
        let expected = try #require(
            FFmpegWrapper.fileSystemIdentity(at: cover, followSymlink: true)
        )
        try FileManager.default.removeItem(at: cover)
        try data.write(to: cover)

        #expect(FFmpegWrapper.loadCoverSnapshot(
            at: cover,
            expectedIdentity: expected
        ) == nil)
    }

    @Test("Ein bereits abgebrochener Cover-Snapshot berührt den Pfad nicht")
    func coverSnapshotStopsBeforeIOWhenCancelled() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("cover-fifo.jpg")
        let fifoResult = fifo.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.mkfifo($0, mode_t(0o600)) } ?? -1
        }
        #expect(fifoResult == 0)

        let start = Date()
        #expect(FFmpegWrapper.loadCoverSnapshot(
            at: fifo,
            isCancelled: { true }
        ) == nil)
        #expect(Date().timeIntervalSince(start) < 0.1)
    }
}
