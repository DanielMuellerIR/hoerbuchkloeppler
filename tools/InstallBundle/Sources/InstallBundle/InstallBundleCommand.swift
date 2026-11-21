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
        if arguments.count == 6, arguments[0] == "snapshot", let pid = Int32(arguments[3]) {
            let target = try BundleInstallation.capture(parentPath: arguments[1], destination: arguments[2], runPID: pid)
            guard target.parentIdentity.statIdentity == arguments[4] else {
                throw InstallError.changed(target.parentPath)
            }
            guard (target.previousIdentity?.statIdentity ?? "missing") == arguments[5] else {
                throw InstallError.changed(target.destination)
            }
            try printToken(target)
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
