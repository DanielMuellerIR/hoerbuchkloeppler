import Foundation

enum CapturedProcessResult: Sendable {
    case completed(status: Int32, output: Data)
    case timedOut(output: Data)
    case cancelled(output: Data)
    case failed(String)
}

enum ProcessRunner {
    static func capture(
        executableURL: URL,
        arguments: [String],
        context: ToolProcessContext? = nil,
        timeout: TimeInterval
    ) -> CapturedProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Kein Werkzeug hier liest von stdin. Ohne diese Zeile erbt das Kind den
        // stdin der App beziehungsweise das Terminal der CLI.
        process.standardInput = FileHandle.nullDevice
        let reader = ProcessPipeReader(handle: pipe.fileHandleForReading, maximumBytes: 32 * 1024 * 1024, requiresCompleteOutput: true)
        do {
            let started: Bool
            if let context {
                started = try context.run(process)
            } else {
                try process.run()
                ProcessTerminator.recordOwnedProcessGroup(process)
                started = true
            }
            guard started else { return .cancelled(output: Data()) }
            defer {
                if let context {
                    context.unregister(process)
                } else {
                    ProcessTerminator.forgetOwnedProcessGroup(process)
                }
            }
            try? pipe.fileHandleForWriting.close()
            reader.start()

            let boundedTimeout = timeout.isFinite ? max(0, timeout) : 5
            ProcessTerminator.wait(upTo: boundedTimeout) { process.isRunning }
            let timedOut = process.isRunning
            if timedOut {
                ProcessTerminator.terminateAndWait([process])
            }
            // Ein Prozess im nicht unterbrechbaren Kernel-Wait — etwa auf einem
            // abgerissenen Netz-Mount — überlebt auch SIGKILL, bis sein I/O
            // zurückkommt. Ein unbedingtes `waitUntilExit()` blockierte hier
            // trotz der angegebenen Frist unbegrenzt.
            let exited = !process.isRunning
            if exited { process.waitUntilExit() }
            // Auch kurze Hilfsaufrufe dürfen keinen vom Wrapper abgekoppelten
            // Nachkommen im eigenen Prozessbaum zurücklassen.
            ProcessTerminator.terminateRemainingOwnedGroup(process)
            // Ein bereits beendeter direkter Prozess kann einen Nachkommen mit
            // geerbtem stdout hinterlassen. Dessen offener Schreibdeskriptor darf
            // den informativen Versions-/MediaInfo-Aufruf nicht endlos blockieren.
            let output = reader.waitUntilEOF(timeout: 0.25)
            if context?.isCancelled == true { return .cancelled(output: output) }
            // Eine gekürzte Ausgabe darf nicht wie eine vollständige aussehen:
            // Aus halben MediaInfo-Daten entstünden sonst falsche Titel- und
            // Autorvorschläge, ohne dass jemand gewarnt wird.
            if timedOut || !exited || reader.joinTimedOut {
                return .timedOut(output: output)
            }
            if reader.failedToReadOutput { return .failed("Werkzeugausgabe konnte nicht vollständig gelesen werden.") }
            if reader.exceededOutputLimit { return .failed("Werkzeugausgabe überschreitet 32 MiB; vollständige Analyse nicht möglich.") }
            return .completed(status: process.terminationStatus, output: output)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
