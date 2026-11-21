import Foundation
import Testing
@testable import HoerbuchkloepplerCore
import Darwin

@Suite("Prozessübergreifende Zielsperren")
struct OutputLeaseTests {
    @Test("Nur ein Lauf kann dasselbe Ziel reservieren")
    func outputLeaseIsExclusiveWithinProcess() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("Buch.m4b")
        var first: OutputLeaseSet? = try FFmpegWrapper.acquireOutputLeases(for: [output])
        _ = withExtendedLifetime(first) {
            #expect(throws: ConversionOutputError.self) {
                _ = try FFmpegWrapper.acquireOutputLeases(for: [output])
            }
        }
        first = nil
        _ = try FFmpegWrapper.acquireOutputLeases(for: [output])
    }

    @Test("Case-insensitive Zielschreibweisen teilen Lease und Lock-Datei")
    func caseInsensitiveLeaseKeysMatch() {
        let upper = URL(fileURLWithPath: "/tmp/Buch.m4b")
        let lower = URL(fileURLWithPath: "/tmp/buch.m4b")
        #expect(
            FFmpegWrapper.outputLeaseKey(
                for: upper,
                caseSensitiveNames: false
            ) == FFmpegWrapper.outputLeaseKey(
                for: lower,
                caseSensitiveNames: false
            )
        )
        #expect(
            FFmpegWrapper.outputLockURL(
                for: upper,
                caseSensitiveNames: false
            ).lastPathComponent == FFmpegWrapper.outputLockURL(
                for: lower,
                caseSensitiveNames: false
            ).lastPathComponent
        )
        #expect(
            FFmpegWrapper.outputLeaseKey(
                for: upper,
                caseSensitiveNames: true
            ) != FFmpegWrapper.outputLeaseKey(
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
        var lease: OutputLeaseSet? = try FFmpegWrapper.acquireOutputLeases(for: [output])
        let lockPath = FFmpegWrapper.outputLockURL(for: output).path
        let script = """
        import fcntl, sys
        handle = open(sys.argv[1], 'a')
        try:
            fcntl.lockf(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit(9)
        """

        let blocked = withExtendedLifetime(lease) {
            FFmpegWrapper.runCapturedProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", script, lockPath],
                timeout: 2
            )
        }
        guard case .completed(let blockedStatus, _) = blocked else {
            Issue.record("Zweiter Prozess lieferte keinen Exit-Status")
            return
        }
        #expect(blockedStatus == 9)

        lease = nil
        let available = FFmpegWrapper.runCapturedProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script, lockPath],
            timeout: 2
        )
        guard case .completed(let availableStatus, _) = available else {
            Issue.record("Zweiter Prozess lieferte nach Freigabe keinen Exit-Status")
            return
        }
        #expect(availableStatus == 0)
    }
}
