import Darwin
import Foundation

@main
struct InstallBundleCommand {
    private enum Operation: String {
        case requireOriginal = "require-original"
        case requireInstalled = "require-installed"
        case stagingPath = "staging-path"
        case stage, replace, cleanup, rollback, discard
    }

    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            diagnose("✗ \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        if arguments.count == 6, arguments[0] == "run-locked", let pid = Int32(arguments[3]) {
            try runLocked(parentPath: arguments[1], destination: arguments[2], runPID: pid,
                          expectedParent: arguments[4], expectedDestination: arguments[5])
            return
        }
        guard arguments.count >= 2, let operation = Operation(rawValue: arguments[1]) else {
            throw InstallError.invalidArguments
        }
        let target = try JSONDecoder().decode(BundleInstallation.self, from: Data(arguments[0].utf8))
        switch operation {
        case .requireOriginal:
            guard arguments.count == 2 else { throw InstallError.invalidArguments }
            try target.requireOriginalDestination()
        case .stagingPath:
            guard arguments.count == 2 else { throw InstallError.invalidArguments }
            print(target.stagingPath)
        case .stage:
            guard arguments.count == 2 else { throw InstallError.invalidArguments }
            try printToken(target.createStaging())
        case .replace, .requireInstalled, .cleanup, .rollback, .discard:
            guard arguments.count == 3 else { throw InstallError.invalidArguments }
            let stagedIdentity = try JSONDecoder().decode(FileIdentity.self, from: Data(arguments[2].utf8))
            try apply(operation, to: target, stagedIdentity: stagedIdentity)
        }
    }

    private static func runLocked(
        parentPath: String, destination: String, runPID: Int32,
        expectedParent: String, expectedDestination: String
    ) throws {
        let parent = try InstallDirectory(path: parentPath)
        guard try parent.identity().statIdentity == expectedParent else {
            throw InstallError.changed(parentPath)
        }
        // Der Deskriptor bleibt beim exec offen und hält die Sperre bis zum
        // Ende der Shell samt etwaigem Rollback. Der Elternordner ist auch
        // bei einer Erstinstallation vorhanden und braucht keine Sperrdatei.
        let lock = try parent.acquireInstallationLock(for: parentPath)
        defer { close(lock) }
        let target = try BundleInstallation.capture(parentPath: parentPath, destination: destination, runPID: runPID)
        guard target.parentIdentity.statIdentity == expectedParent,
              (target.previousIdentity?.statIdentity ?? "missing") == expectedDestination else {
            throw InstallError.changed(target.destinationPath)
        }
        let token = String(decoding: try JSONEncoder().encode(target), as: UTF8.self)
        guard setenv("INSTALL_TARGET", token, 1) == 0 else {
            throw InstallError.posix("INSTALL_TARGET", errno)
        }
        let shell = "/bin/bash"
        let arguments = [shell, "-c", "run_installation"]
        var argv = arguments.map { strdup($0) }
        argv.append(nil)
        defer { for argument in argv { free(argument) } }
        _ = execv(shell, &argv)
        throw InstallError.posix(shell, errno)
    }

    private static func apply(_ operation: Operation, to target: BundleInstallation,
                              stagedIdentity: FileIdentity) throws {
        switch operation {
        case .replace:
            try target.replace(with: stagedIdentity)
        case .requireInstalled:
            try target.requireInstalled(stagedIdentity: stagedIdentity)
        case .cleanup:
            for warning in try target.cleanupAfterVerification(stagedIdentity: stagedIdentity) {
                diagnose("⚠ Backup-/Staging-Rest bleibt erhalten: \(warning)")
            }
        case .rollback:
            let rollback: BundleInstallation.Rollback
            do {
                rollback = try target.rollback(stagedIdentity: stagedIdentity)
            } catch {
                if target.previousIdentity == nil {
                    diagnose("✗ KRITISCH: Erstinstallation konnte nicht zurückgezogen werden: \(target.destinationPath)")
                } else {
                    diagnose("✗ KRITISCH: Rückzug fehlgeschlagen. Voriges Bundle unter \(target.backupPath) oder \(target.stagingPath) prüfen.")
                }
                throw error
            }
            switch rollback {
            case .unnecessary:
                break
            case .removedFirstInstallation:
                diagnose("⚠ Fehlgeschlagene Erstinstallation wurde entfernt.")
            case .restoredPreviousBundle(let cleanupWarning):
                diagnose("⚠ Fehlgeschlagene Installation wurde auf das vorige Bundle zurückgerollt.")
                if let cleanupWarning {
                    diagnose("⚠ Der Rest der fehlgeschlagenen Installation bleibt erhalten: \(cleanupWarning)")
                }
            }
        case .discard:
            try target.discardStaging(stagedIdentity: stagedIdentity)
        case .stage, .requireOriginal, .stagingPath:
            throw InstallError.invalidArguments
        }
    }

    private static func printToken<T: Encodable>(_ value: T) throws {
        print(String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
    }

    private static func diagnose(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
