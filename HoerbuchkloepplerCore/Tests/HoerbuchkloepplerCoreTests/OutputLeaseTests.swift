import Foundation
import Testing
@testable import HoerbuchkloepplerCore
import Darwin

@Suite("Prozessübergreifende Zielsperren")
struct OutputLeaseTests {
    private let tryExclusiveLock = """
        import fcntl, sys
        handle = open(sys.argv[1], 'a')
        try:
            fcntl.lockf(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit(9)
        """

    @Test("Nur ein Lauf kann dasselbe Ziel reservieren")
    func outputLeaseIsExclusiveWithinProcess() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("Buch.m4b")
        var first: OutputLeaseSet? = try OutputLeases.acquire(for: [output])
        _ = withExtendedLifetime(first) {
            #expect(throws: ConversionOutputError.self) {
                _ = try OutputLeases.acquire(for: [output])
            }
        }
        first = nil
        _ = try OutputLeases.acquire(for: [output])
    }

    @Test("Case-insensitive Zielschreibweisen teilen Lease und Lock-Datei")
    func caseInsensitiveLeaseKeysMatch() {
        let upper = URL(fileURLWithPath: "/tmp/Buch.m4b")
        let lower = URL(fileURLWithPath: "/tmp/buch.m4b")
        #expect(
            OutputLeases.outputLeaseKey(
                for: upper,
                caseSensitiveNames: false
            ) == OutputLeases.outputLeaseKey(
                for: lower,
                caseSensitiveNames: false
            )
        )
        #expect(
            OutputLeases.outputLockURL(
                for: upper,
                caseSensitiveNames: false
            ).lastPathComponent == OutputLeases.outputLockURL(
                for: lower,
                caseSensitiveNames: false
            ).lastPathComponent
        )
        #expect(
            OutputLeases.outputLeaseKey(
                for: upper,
                caseSensitiveNames: true
            ) != OutputLeases.outputLeaseKey(
                for: lower,
                caseSensitiveNames: true
            )
        )
    }

    @Test("Die Zielreservierung gilt auch gegenüber einem zweiten Prozess")
    func outputLeaseIsExclusiveAcrossProcesses() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("Buch.m4b")
        var lease: OutputLeaseSet? = try OutputLeases.acquire(for: [output])
        let lockPath = OutputLeases.outputLockURL(for: output).path
        let blocked = withExtendedLifetime(lease) {
            ProcessRunner.capture(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", tryExclusiveLock, lockPath],
                timeout: 2
            )
        }
        guard case .completed(let blockedStatus, _) = blocked else {
            Issue.record("Zweiter Prozess lieferte keinen Exit-Status")
            return
        }
        #expect(blockedStatus == 9)

        lease = nil
        let available = ProcessRunner.capture(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", tryExclusiveLock, lockPath],
            timeout: 2
        )
        guard case .completed(let availableStatus, _) = available else {
            Issue.record("Zweiter Prozess lieferte nach Freigabe keinen Exit-Status")
            return
        }
        #expect(availableStatus == 0)
    }

    @Test("Ein ersetzter Zielsymlink bleibt bis zum Ende des Exports gesperrt")
    func outputLeaseRemainsHeldWhenTargetSymlinkIsReplaced() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let linked = directory.appendingPathComponent("Original.m4b")
        try Data("Erhalten".utf8).write(to: linked)
        let output = directory.appendingPathComponent("Buch.m4b")
        try FileManager.default.createSymbolicLink(at: output, withDestinationURL: linked)
        let legacyLock = OutputLeases.outputLockURL(for: output)
        var lease: OutputLeaseSet? = try OutputLeases.acquire(for: [output])

        let replacement = directory.appendingPathComponent("staging.m4b")
        try Data("Neu".utf8).write(to: replacement)
        try #require(replacement.path.withCString { staged in
            output.path.withCString { target in
                Darwin.renameatx_np(AT_FDCWD, staged, AT_FDCWD, target, UInt32(RENAME_SWAP))
            }
        } == 0)
        let currentLock = OutputLeases.outputLockURL(for: output)
        #expect(legacyLock != currentLock)

        withExtendedLifetime(lease) {
            #expect(throws: ConversionOutputError.self) { _ = try OutputLeases.acquire(for: [output]) }
            for lock in [legacyLock, currentLock] {
                let result = ProcessRunner.capture(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: ["-c", tryExclusiveLock, lock.path],
                    timeout: 2)
                guard case .completed(let status, _) = result else {
                    Issue.record("Zweiter Prozess lieferte keinen Exit-Status")
                    continue
                }
                #expect(status == 9)
            }
        }
        lease = nil
        _ = try OutputLeases.acquire(for: [output])
        #expect(try String(contentsOf: linked, encoding: .utf8) == "Erhalten")
    }
}
