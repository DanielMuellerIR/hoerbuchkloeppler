import Foundation

struct BundleInstallation: Codable {
    let parentPath: String
    let destination: String
    let runPID: Int32
    let parentIdentity: FileIdentity
    let previousIdentity: FileIdentity?

    var staging: String { ".\(destination.dropLast(4)).install-\(runPID).app" }
    var backup: String { ".\(destination.dropLast(4)).backup-\(runPID).app" }
    var stagingPath: String { "\(parentPath)/\(staging)" }
    var backupPath: String { "\(parentPath)/\(backup)" }
    var destinationPath: String { "\(parentPath)/\(destination)" }

    private var originalDestination: DirectoryEntry {
        previousIdentity.map(DirectoryEntry.directory) ?? .missing
    }

    static func capture(parentPath: String, destination: String, runPID: Int32) throws -> BundleInstallation {
        try validate(parentPath: parentPath, destination: destination, runPID: runPID)
        let parent = try InstallDirectory(path: parentPath)
        let previousIdentity: FileIdentity?
        switch try parent.entry(destination) {
        case .missing: previousIdentity = nil
        case .directory(let identity): previousIdentity = identity
        case .other: throw InstallError.unsuitableTarget("\(parentPath)/\(destination)")
        }
        return BundleInstallation(parentPath: parentPath, destination: destination, runPID: runPID,
                                  parentIdentity: try parent.identity(), previousIdentity: previousIdentity)
    }

    func requireOriginalDestination() throws {
        try openParent().require(destination, toBe: originalDestination)
    }

    func createStaging() throws -> FileIdentity {
        let parent = try openParent()
        try parent.require(destination, toBe: originalDestination)
        try requireAvailableBackup(in: parent)
        return try parent.create(staging)
    }

    func replace(with stagedIdentity: FileIdentity) throws {
        let parent = try openParent()
        try parent.require(destination, toBe: originalDestination)
        try requireAvailableBackup(in: parent)
        if let previousIdentity {
            // Zwischen Austausch und Backup liegt das vorige Bundle unter dem
            // Staging-Namen. Der Rückzug erkennt es an beiden Stellen.
            try parent.swap(staging, ownedBy: stagedIdentity, with: destination, ownedBy: previousIdentity)
            try parent.move(staging, to: backup, ownedBy: previousIdentity)
        } else {
            try parent.move(staging, to: destination, ownedBy: stagedIdentity)
        }
    }

    func requireInstalled(stagedIdentity: FileIdentity) throws {
        try openParent().require(destination, toBe: .directory(stagedIdentity))
    }

    func cleanupAfterVerification(stagedIdentity: FileIdentity) throws -> [String] {
        let parent = try openParent()
        try parent.require(destination, toBe: .directory(stagedIdentity))
        return [cleanup(backup, identity: previousIdentity, in: parent),
                cleanup(staging, identity: stagedIdentity, in: parent)].compactMap { $0 }
    }

    enum Rollback {
        case unnecessary
        case removedFirstInstallation
        case restoredPreviousBundle(cleanupWarning: String?)
    }

    func rollback(stagedIdentity: FileIdentity) throws -> Rollback {
        let parent = try openParent()
        let installed = try parent.entry(destination)
        if installed == originalDestination { return .unnecessary }
        guard installed == .directory(stagedIdentity) || installed == .missing else {
            throw InstallError.changed(destination)
        }
        guard let previousIdentity else {
            try parent.removeOwned(destination, identity: stagedIdentity)
            return .removedFirstInstallation
        }
        let previousBundle = try locatePreviousBundle(in: parent, identity: previousIdentity)
        if installed == .missing {
            try parent.move(previousBundle, to: destination, ownedBy: previousIdentity)
        } else {
            try parent.swap(previousBundle, ownedBy: previousIdentity, with: destination, ownedBy: stagedIdentity)
        }
        return .restoredPreviousBundle(cleanupWarning: cleanup(previousBundle, identity: stagedIdentity, in: parent))
    }

    func discardStaging(stagedIdentity: FileIdentity) throws {
        try openParent().removeOwned(staging, identity: stagedIdentity)
    }

    private func openParent() throws -> InstallDirectory {
        try Self.validate(parentPath: parentPath, destination: destination, runPID: runPID)
        let parent = try InstallDirectory(path: parentPath)
        guard try parent.identity() == parentIdentity else { throw InstallError.changed(parentPath) }
        return parent
    }

    private func requireAvailableBackup(in parent: InstallDirectory) throws {
        guard try parent.entry(backup) == .missing else { throw InstallError.occupied(backup) }
    }

    private func locatePreviousBundle(in parent: InstallDirectory, identity: FileIdentity) throws -> String {
        for entry in [backup, staging] {
            if try parent.entry(entry) == .directory(identity) { return entry }
        }
        throw InstallError.previousBundleMissing
    }

    private func cleanup(_ name: String, identity: FileIdentity?, in parent: InstallDirectory) -> String? {
        do {
            if let identity {
                try parent.removeOwned(name, identity: identity)
            } else if try parent.entry(name) != .missing {
                throw InstallError.changed(name)
            }
            return nil
        } catch {
            return "\(parentPath)/\(name) (\(error.localizedDescription))"
        }
    }

    private static func validate(parentPath: String, destination: String, runPID: Int32) throws {
        guard parentPath.hasPrefix("/"), parentPath != "/", !parentPath.contains("\0"),
              destination.hasSuffix(".app"), !destination.contains("/"), !destination.contains("\0"),
              runPID > 0 else {
            throw InstallError.invalidArguments
        }
    }
}
