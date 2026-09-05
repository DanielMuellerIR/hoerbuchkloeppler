import Foundation
import Testing
@testable import HoerbuchkloepplerCore

@Suite("Ressourcenbegrenzung")
struct ResourceLimitTests {
    @Test func workerSettingsRoundTrip() throws {
        let settings = AudioSettings(workerLimit: 2)
        #expect(try JSONDecoder().decode(AudioSettings.self, from: JSONEncoder().encode(settings)) == settings)
        #expect(AudioSettings(workerLimit: 0).normalized().workerLimit == nil)
        #expect(AudioSettings(workerLimit: 33).normalized().workerLimit == nil)
        #expect(AudioSettings().effectiveWorkerLimit <= 4)
        let invocation = CLIInvocation(executable: "kloeppler", folderURL: URL(fileURLWithPath: "/tmp"), settings: settings, title: "", author: "", genre: "")
        #expect(invocation.arguments.suffix(2) == ["--workers", "2"])
    }

    @Test func boundedDiagnosticStillDeliversEveryChunk() throws {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var bytes = 0
            func add(_ count: Int) { lock.lock(); bytes += count; lock.unlock() }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import sys; sys.stdout.buffer.write(b'x'*1000000+b'END')"]
        let pipe = Pipe()
        process.standardOutput = pipe
        let reader = ProcessPipeReader(handle: pipe.fileHandleForReading, maximumBytes: 1024)
        let counter = Counter()
        try process.run()
        try pipe.fileHandleForWriting.close()
        reader.start { counter.add($0.count) }
        process.waitUntilExit()
        let data = reader.waitUntilEOF(timeout: 2)
        #expect(counter.bytes == 1_000_003)
        #expect(data.count < 1200)
        #expect(data.suffix(3) == Data("END".utf8))
        #expect(reader.exceededOutputLimit)
        #expect(String(decoding: data, as: UTF8.self).contains("Diagnose gekürzt"))
    }

    @Test func completeOutputReportsOverflow() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "print('x'*5000)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        let reader = ProcessPipeReader(handle: pipe.fileHandleForReading, maximumBytes: 1024, requiresCompleteOutput: true)
        try process.run()
        try pipe.fileHandleForWriting.close()
        reader.start()
        process.waitUntilExit()
        #expect(reader.waitUntilEOF(timeout: 2).count == 1024)
        #expect(reader.exceededOutputLimit)
    }

    @Test func fatalFailureTerminatesAndRejectsFurtherStarts() throws {
        let context = ConversionContext()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        #expect(try context.run(process))
        context.failSegments()
        #expect(!process.isRunning)
        #expect(context.hasSegmentFailure)
        #expect(!context.isCancelled)
        let next = Process()
        next.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        #expect(try !context.run(next))
        context.unregister(process)
    }
}
