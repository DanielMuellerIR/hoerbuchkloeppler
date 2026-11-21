import Foundation
import Testing
@testable import HoerbuchkloepplerCore
import Darwin

@Suite("Besitz und Bereinigung von Arbeitsverzeichnissen")
struct TemporaryDirectoryTests {
    @Test("Vorbestehendes Temp-Verzeichnis wird nicht beansprucht")
    func tempCreationIsExclusive() throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("HB_Temp_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let sentinel = directory.appendingPathComponent("wichtig.txt")
        try Data("behalten".utf8).write(to: sentinel)

        #expect(throws: (any Error).self) {
            try FFmpegWrapper.createOwnedTempDirectory(directory)
        }
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test("Ausgetauschte Temp-Verzeichnisse bleiben bei Abschluss und Abbruch erhalten")
    func replacedTempDirectoryIsNotRemoved() throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for cancel in [false, true] {
            let directory = root.appendingPathComponent("HB_Temp_\(UUID().uuidString)")
            let parked = root.appendingPathComponent("ursprünglich-\(UUID().uuidString)")
            try FFmpegWrapper.createOwnedTempDirectory(directory)
            let context = ConversionContext()
            context.registerTempDirectory(directory)
            try FileManager.default.moveItem(at: directory, to: parked)
            try FFmpegWrapper.createOwnedTempDirectory(directory)
            let sentinel = directory.appendingPathComponent("wichtig.txt")
            try Data("behalten".utf8).write(to: sentinel)

            if cancel {
                context.cancel()
                #expect(context.waitForCancellationCleanup())
            } else {
                context.removeTempDirectory(directory)
            }

            #expect(FileManager.default.fileExists(atPath: sentinel.path))
            #expect(FileManager.default.fileExists(atPath: parked.path))
        }
    }

    @Test("Eigene Temp-Verzeichnisse werden trotz erzeugter Kinddateien entfernt")
    func populatedTempDirectoriesAreRemoved() throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for cancel in [false, true] {
            let directory = root.appendingPathComponent("HB_Temp_\(UUID().uuidString)")
            try FFmpegWrapper.createOwnedTempDirectory(directory)
            let context = ConversionContext()
            context.registerTempDirectory(directory)
            try Data("Segment".utf8).write(
                to: directory.appendingPathComponent("seg_0.wav")
            )

            if cancel {
                context.cancel()
                #expect(context.waitForCancellationCleanup())
            } else {
                context.removeTempDirectory(directory)
            }

            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @Test("Temp-Cleanup rollt einen Austausch nach der Vorprüfung zurück")
    func tempCleanupRechecksQuarantinedEntry() throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("HB_Temp_\(UUID().uuidString)")
        let parked = root.appendingPathComponent("ursprünglich")
        try FFmpegWrapper.createOwnedTempDirectory(directory)
        let identity = try #require(
            FFmpegWrapper.fileSystemIdentity(at: directory, followSymlink: false)
        )
        var hookError: (any Error)?

        FFmpegWrapper.removeOwnedTempDirectory(
            directory,
            expectedIdentity: identity,
            beforeQuarantine: {
                do {
                    try FileManager.default.moveItem(at: directory, to: parked)
                    try FFmpegWrapper.createOwnedTempDirectory(directory)
                    try Data("behalten".utf8).write(
                        to: directory.appendingPathComponent("wichtig.txt")
                    )
                } catch {
                    hookError = error
                }
            }
        )

        #expect(hookError == nil)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("wichtig.txt").path
        ))
        #expect(FileManager.default.fileExists(atPath: parked.path))
    }

    @Test("Temp-Cleanup bindet die rekursive Löschung an den geprüften Inode")
    func tempCleanupReopensQuarantineByIdentity() throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("HB_Temp_\(UUID().uuidString)")
        let parked = root.appendingPathComponent("ursprüngliche-quarantaene")
        try FFmpegWrapper.createOwnedTempDirectory(directory)
        try Data("eigen".utf8).write(
            to: directory.appendingPathComponent("segment.m4a")
        )
        let identity = try #require(
            FFmpegWrapper.fileSystemIdentity(at: directory, followSymlink: false)
        )
        var replacementURL: URL?
        var hookError: (any Error)?

        FFmpegWrapper.removeOwnedTempDirectory(
            directory,
            expectedIdentity: identity,
            beforeBoundRemoval: {
                do {
                    let quarantine = try #require(
                        FileManager.default.contentsOfDirectory(
                            at: root,
                            includingPropertiesForKeys: nil
                        ).first { $0.lastPathComponent.hasPrefix(".HB_Cleanup_") }
                    )
                    try FileManager.default.moveItem(at: quarantine, to: parked)
                    try FileManager.default.createDirectory(
                        at: quarantine,
                        withIntermediateDirectories: false
                    )
                    try Data("behalten".utf8).write(
                        to: quarantine.appendingPathComponent("wichtig.txt")
                    )
                    replacementURL = quarantine
                } catch {
                    hookError = error
                }
            }
        )

        let replacement = try #require(replacementURL)
        #expect(hookError == nil)
        #expect(FileManager.default.fileExists(
            atPath: replacement.appendingPathComponent("wichtig.txt").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: parked.appendingPathComponent("segment.m4a").path
        ))
    }

    @Test("Altlastenbereinigung verlangt exakten Namen und gültigen Besitzer")
    func orphanCleanupRequiresOwnershipProof() throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unowned = root.appendingPathComponent("HB_Temp_\(UUID().uuidString)")
        let orphan = root.appendingPathComponent("HB_Temp_\(UUID().uuidString)")
        let misleading = root.appendingPathComponent("HB_Temp_nicht-eine-uuid")
        for directory in [unowned, misleading] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        try FFmpegWrapper.createOwnedTempDirectory(orphan)
        try "987654".write(
            to: orphan.appendingPathComponent(".owner-pid"),
            atomically: true,
            encoding: .utf8
        )
        let old = Date(timeIntervalSince1970: 1)
        for directory in [unowned, orphan, misleading] {
            try FileManager.default.setAttributes(
                [.creationDate: old],
                ofItemAtPath: directory.path
            )
        }

        FFmpegWrapper.cleanupOldTempDirectories(
            in: root,
            now: Date(timeIntervalSince1970: 200_000)
        )

        #expect(FileManager.default.fileExists(atPath: unowned.path))
        #expect(FileManager.default.fileExists(atPath: misleading.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test("Temp-Sweep erhält fremde Recovery-Daten auch nach Ausgabe-Cleanup")
    func tempSweepPreservesRecordedRecovery() throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cleanup = root.appendingPathComponent(".HB_Cleanup_987654-\(UUID().uuidString)")
        try FFmpegWrapper.createOwnedTempDirectory(cleanup, ownerPID: 987654)
        let entry = cleanup.appendingPathComponent("entry")
        try Data("eigener Rest".utf8).write(to: entry)
        let identity = try #require(FFmpegWrapper.fileSystemIdentity(at: entry, followSymlink: false))
        try FFmpegWrapper.writeCleanupEntryIdentity(identity, in: cleanup)
        try Data("Recovery".utf8).write(to: cleanup.appendingPathComponent("fremd.txt"))
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: cleanup.path)
        FFmpegWrapper.cleanupOutputQuarantines(in: root)
        for _ in 0..<2 {
            FFmpegWrapper.cleanupOldTempDirectories(in: root, now: Date(timeIntervalSince1970: 200_000))
        }
        let remains = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(remains.count == 1)
        let remaining = try #require(remains.first)
        #expect(try Data(contentsOf: remaining.appendingPathComponent("fremd.txt")) == Data("Recovery".utf8))
        #expect(FileManager.default.fileExists(atPath: remaining.appendingPathComponent(".entry-identity.json").path))
    }

    @Test("Temp-Sweep erhält ungültige Cleanup-Nachweise und entfernt alte Lautheits-WAVs")
    func tempSweepHonorsInvalidRecordsAndLegacyLoudness() throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = root.appendingPathComponent(".HB_Cleanup_987654-\(UUID().uuidString)")
        let loudness = root.appendingPathComponent("HB_Loudness_\(UUID().uuidString)")
        for directory in [invalid, loudness] {
            try FFmpegWrapper.createOwnedTempDirectory(directory, ownerPID: 987654)
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: directory.path)
        }
        try Data("defekt".utf8).write(to: invalid.appendingPathComponent(".entry-identity.json"))
        try Data("WAV-Rest".utf8).write(to: loudness.appendingPathComponent("audio.wav"))
        FFmpegWrapper.cleanupOldTempDirectories(in: root, now: Date(timeIntervalSince1970: 200_000))
        #expect(FileManager.default.fileExists(atPath: invalid.path))
        #expect(!FileManager.default.fileExists(atPath: loudness.path))
    }

    @Test("Altlastenbereinigung erfasst markierte Cleanup-Quarantänen")
    func orphanCleanupRemovesOwnedCleanupQuarantine() throws {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cleanup = root.appendingPathComponent(
            ".HB_Cleanup_987654-\(UUID().uuidString)"
        )
        let decoy = root.appendingPathComponent(
            ".HB_Cleanup_987654-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: cleanup, withIntermediateDirectories: false)
        try "987654".write(
            to: cleanup.appendingPathComponent(".owner-pid"),
            atomically: true,
            encoding: .utf8
        )
        try Data("rest".utf8).write(to: cleanup.appendingPathComponent("segment.m4a"))
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: false)
        let old = Date(timeIntervalSince1970: 1)
        for directory in [cleanup, decoy] {
            try FileManager.default.setAttributes(
                [.creationDate: old],
                ofItemAtPath: directory.path
            )
        }

        FFmpegWrapper.cleanupOldTempDirectories(
            in: root,
            now: Date(timeIntervalSince1970: 200_000)
        )

        #expect(!FileManager.default.fileExists(atPath: cleanup.path))
        #expect(FileManager.default.fileExists(atPath: decoy.path))
    }
}
