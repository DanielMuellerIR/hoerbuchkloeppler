import Darwin
import Foundation
import Testing
@testable import InstallBundle

struct BundleInstallationTests {
    @Test func previousBundleCanBeRestoredAfterSwapBeforeBackupMove() throws {
        try withFixture(existing: true) { parent, installation in
            let staged = try installation.createStaging()
            let previous = try #require(installation.previousIdentity)
            let directory = try InstallDirectory(path: parent.path)

            // Zustand nach einem erfolgreichen Swap, dessen Backup-Move ausbleibt.
            try directory.swap(installation.staging, ownedBy: staged,
                               with: installation.destination, ownedBy: previous)
            try writeBundle(parent.appendingPathComponent(installation.backup), version: "fremd")

            let result = try installation.rollback(stagedIdentity: staged)

            guard case .restoredPreviousBundle(cleanupWarning: nil) = result else {
                Issue.record("Erwartete Wiederherstellung aus dem Staging")
                return
            }
            try installation.requireOriginalDestination()
            #expect(try directory.entry(installation.staging) == .missing)
            #expect(try version(in: parent.appendingPathComponent(installation.backup)) == "fremd")
        }
    }

    @Test func backupCollisionPreventsReplacement() throws {
        try withFixture(existing: true) { parent, installation in
            let staged = try installation.createStaging()
            let backup = parent.appendingPathComponent(installation.backup)
            try writeBundle(backup, version: "fremd")

            #expect(throws: InstallError.self) {
                try installation.replace(with: staged)
            }

            try installation.requireOriginalDestination()
            try installation.discardStaging(stagedIdentity: staged)
            #expect(try version(in: backup) == "fremd")
        }
    }

    @Test func exclusiveMovePreservesDestination() throws {
        try withFixture(existing: false) { parent, installation in
            let staged = try installation.createStaging()
            let destination = parent.appendingPathComponent(installation.destination)
            try writeBundle(destination, version: "fremd")
            let directory = try InstallDirectory(path: parent.path)

            #expect(throws: InstallError.self) {
                try directory.move(installation.staging, to: installation.destination, ownedBy: staged)
            }

            #expect(try version(in: destination) == "fremd")
            #expect(try directory.entry(installation.staging) == .directory(staged))
        }
    }

    @Test func exclusiveMoveLeavesSubstitutedDestinationAtItsOwnPath() throws {
        try withFixture(existing: false) { parent, installation in
            let staged = try installation.createStaging()
            let destination = parent.appendingPathComponent(installation.destination)
            let movedAside = parent.appendingPathComponent("Abgelöste Installation.app")
            let directory = try InstallDirectory(path: parent.path) { fd, source, target, flags in
                try renameEntry(fd, source, target, flags)
                if source == installation.staging {
                    try FileManager.default.moveItem(at: destination, to: movedAside)
                    try writeBundle(destination, version: "fremd")
                }
            }

            #expect(throws: InstallError.self) {
                try directory.move(installation.staging, to: installation.destination, ownedBy: staged)
            }

            #expect(try directory.entry(installation.staging) == .missing)
            #expect(try version(in: destination) == "fremd")
            #expect(try directory.entry(movedAside.lastPathComponent) == .directory(staged))
        }
    }

    @Test(arguments: [true, false])
    func swapLeavesSubstitutedEntryAndOtherSlotInPlace(replaceStaging: Bool) throws {
        try withFixture(existing: true) { parent, installation in
            let staged = try installation.createStaging()
            let previous = try #require(installation.previousIdentity)
            let substituted = replaceStaging ? installation.staging : installation.destination
            let displacedIdentity = replaceStaging ? previous : staged
            let retainedSlot = replaceStaging ? installation.destination : installation.staging
            let retainedIdentity = replaceStaging ? staged : previous
            let replacedURL = parent.appendingPathComponent(substituted)
            let movedAside = parent.appendingPathComponent("Abgelöstes Bundle.app")
            var renamed = false
            let directory = try InstallDirectory(path: parent.path) { fd, source, target, flags in
                try renameEntry(fd, source, target, flags)
                if !renamed {
                    renamed = true
                    try FileManager.default.moveItem(at: replacedURL, to: movedAside)
                    try writeBundle(replacedURL, version: "fremd")
                }
            }

            #expect(throws: InstallError.self) {
                try directory.swap(installation.staging, ownedBy: staged,
                                   with: installation.destination, ownedBy: previous)
            }

            #expect(try version(in: replacedURL) == "fremd")
            #expect(try directory.entry(movedAside.lastPathComponent) == .directory(displacedIdentity))
            #expect(try directory.entry(retainedSlot) == .directory(retainedIdentity))
        }
    }

    @Test func stagingCleanupDoesNotFollowLinks() throws {
        try withFixture(existing: false) { parent, installation in
            let staged = try installation.createStaging()
            let untouched = parent.appendingPathComponent("Anderes.app")
            try writeBundle(untouched, version: "fremd")
            let staging = parent.appendingPathComponent(installation.staging)
            let link = staging.appendingPathComponent("Externer Verweis")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: untouched)

            try installation.discardStaging(stagedIdentity: staged)

            #expect(!FileManager.default.fileExists(atPath: staging.path))
            #expect(try version(in: untouched) == "fremd")
        }
    }

    private func withFixture(existing: Bool, _ run: (URL, BundleInstallation) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("hk-install-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = "Hörbuch Klöppler.app"
        if existing {
            try writeBundle(parent.appendingPathComponent(destination), version: "vorher")
        }
        let installation = try BundleInstallation.capture(
            parentPath: parent.path, destination: destination, runPID: ProcessInfo.processInfo.processIdentifier
        )
        try run(parent, installation)
    }

    private func writeBundle(_ bundle: URL, version: String) throws {
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        try version.write(to: bundle.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
    }

    private func version(in bundle: URL) throws -> String {
        try String(contentsOf: bundle.appendingPathComponent("version.txt"), encoding: .utf8)
    }

    private func renameEntry(_ fd: Int32, _ source: String, _ target: String, _ flags: UInt32) throws {
        guard renameatx_np(fd, source, fd, target, flags) == 0 else {
            throw InstallError.posix("\(source) → \(target)", errno)
        }
    }
}
