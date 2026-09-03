import Foundation
import Darwin

// Prozess-Lebenszyklus: eigene Werkzeugprozesse starten, ihre Ausgabe lesen und
// sie zweistufig beenden. Bewusst getrennt von der Kodierpipeline — hier steht
// nur, WIE ein fremdes Programm ausgeführt und sicher wieder eingefangen wird,
// nicht, wozu.

/// Beendet eigene Tool-Prozesse zweistufig. `terminate()` sendet nur SIGTERM;
/// ffmpeg, MediaInfo oder ein Ersatzprogramm aus PATH darf den Abbruch dadurch
/// nicht unbegrenzt in `waitUntilExit()` festhalten.
enum ProcessTerminator {
    fileprivate struct TerminationTarget: @unchecked Sendable {
        let process: Process
        let group: pid_t?
    }

    struct TerminationRequest: @unchecked Sendable {
        fileprivate let targets: [TerminationTarget]
    }

    private static let queue = DispatchQueue(
        label: "com.hoerbuchkloeppler.process-termination",
        attributes: .concurrent
    )
    static let defaultGraceInterval: TimeInterval = 0.5
    private static let groupLock = NSLock()
    private nonisolated(unsafe) static var ownedGroups: [ObjectIdentifier: pid_t] = [:]

    /// `Process` startet sein Kind auf macOS als Leiter einer neuen Prozessgruppe.
    /// Die Gruppen-ID wird direkt nach `run()` festgehalten, solange der direkte
    /// Prozess sicher noch existiert. So bleibt sie auch nach dessen frühem Ende
    /// verfügbar, wenn ein Nachkomme noch eine geerbte Pipe offen hält.
    static func recordOwnedProcessGroup(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        let liveGroup = Darwin.getpgid(pid)
        // Ein sehr kurzer Wrapper kann zwischen `run()` und `getpgid()` schon
        // beendet sein, während ein Nachkomme seine Prozessgruppe weiterführt.
        // Die negative kill-Probe adressiert genau diese weiterhin eigene Gruppe.
        guard liveGroup == pid || (liveGroup == -1 && Darwin.kill(-pid, 0) == 0) else {
            return
        }
        groupLock.lock()
        ownedGroups[ObjectIdentifier(process)] = pid
        groupLock.unlock()
    }

    static func forgetOwnedProcessGroup(_ process: Process) {
        groupLock.lock()
        ownedGroups.removeValue(forKey: ObjectIdentifier(process))
        groupLock.unlock()
    }

    private static func ownedGroup(for process: Process) -> pid_t? {
        groupLock.lock()
        defer { groupLock.unlock() }
        return ownedGroups[ObjectIdentifier(process)]
    }

    /// Wartet höchstens `seconds` darauf, dass `isPending()` falsch wird, und
    /// prüft dabei im 10-Millisekunden-Takt. Liefert `true`, wenn die Bedingung
    /// vor Ablauf der Frist erfüllt war.
    ///
    /// Vier Stellen im Projekt warteten so auf ein Prozessende, jede mit
    /// eigener Deadline-Arithmetik. Die Frist selbst bleibt bewusst beim
    /// Aufrufer — sie reicht von einer halben Sekunde Schonfrist bis zu einer
    /// Stunde Kapitelanalyse. Gemeinsam sind nur die Fallstricke: eine
    /// nichtendliche oder negative Sekundenangabe wird auf 0 geklemmt, und die
    /// Deadline wird überlaufsicher gebildet, weil `uptimeNanoseconds` plus
    /// eine sehr große Frist sonst überliefe und die Schleife sofort endete.
    @discardableResult
    static func wait(
        upTo seconds: TimeInterval,
        while isPending: () -> Bool
    ) -> Bool {
        let bounded = seconds.isFinite ? max(0, seconds) : 0
        let nanoseconds = UInt64(min(bounded, 86_400) * 1_000_000_000)
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start > UInt64.max - nanoseconds
            ? UInt64.max
            : start + nanoseconds
        while isPending(), DispatchTime.now().uptimeNanoseconds < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !isPending()
    }

    private static func groupIsRunning(_ group: pid_t) -> Bool {
        if Darwin.kill(-group, 0) == 0 { return true }
        return errno != ESRCH
    }

    static func makeTerminationRequest(
        for processes: [Process]
    ) -> TerminationRequest {
        let targets = processes.compactMap { process -> TerminationTarget? in
            let group = ownedGroup(for: process)
            guard process.isRunning || group.map(groupIsRunning) == true else {
                return nil
            }
            return TerminationTarget(process: process, group: group)
        }
        return TerminationRequest(targets: targets)
    }

    static func terminateAndWait(
        _ processes: [Process],
        graceInterval: TimeInterval = defaultGraceInterval
    ) {
        terminateAndWait(
            makeTerminationRequest(for: processes),
            graceInterval: graceInterval
        )
    }

    /// Nach dem Exit des direkten Werkzeugprozesses darf seine besessene
    /// Prozessgruppe keine Nachkommen mehr enthalten. Ein Wrapper könnte sonst
    /// den eigentlichen Encoder im Hintergrund weiterlaufen lassen, während die
    /// bereits teilweise geschriebene Datei als erfolgreich übernommen wird.
    /// Der Rückgabewert sagt, ob ein solcher Rest gefunden und beendet wurde.
    @discardableResult
    static func terminateRemainingOwnedGroup(_ process: Process) -> Bool {
        guard !process.isRunning,
              let group = ownedGroup(for: process),
              groupIsRunning(group) else { return false }
        terminateAndWait([process])
        return true
    }

    static func terminateAndWait(
        _ request: TerminationRequest,
        graceInterval: TimeInterval = defaultGraceInterval
    ) {
        let targets = request.targets
        guard !targets.isEmpty else { return }

        // Allen Prozessen dieselbe Schonfrist geben, statt sie nacheinander um
        // je eine volle Frist zu verlängern.
        for target in targets {
            let process = target.process
            let group = target.group
            if let group {
                _ = Darwin.kill(-group, SIGTERM)
            } else if process.isRunning {
                process.terminate()
            }
        }
        let grace = graceInterval.isFinite
            ? max(0, graceInterval)
            : defaultGraceInterval
        let anyTargetAlive = {
            targets.contains { target in
                target.process.isRunning
                    || target.group.map(groupIsRunning) == true
            }
        }
        wait(upTo: grace, while: anyTargetAlive)
        for target in targets {
            let process = target.process
            let group = target.group
            if let group, groupIsRunning(group) {
                _ = Darwin.kill(-group, SIGKILL)
            } else if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        // Genau der besitzende Worker ruft `waitUntilExit()` auf. Der Terminator
        // beobachtet nur den Status, damit nie zwei Threads dieselbe
        // Process-Instanz gleichzeitig reap-en.
        wait(upTo: 1, while: anyTargetAlive)
    }

    static func requestTermination(
        _ process: Process,
        graceInterval: TimeInterval = defaultGraceInterval
    ) {
        let request = makeTerminationRequest(for: [process])
        guard !request.targets.isEmpty else { return }
        queue.async {
            terminateAndWait(request, graceInterval: graceInterval)
        }
    }

    static func terminateInBackground(
        _ processes: [Process],
        completion: @escaping @Sendable () -> Void
    ) {
        terminateInBackground(
            makeTerminationRequest(for: processes),
            completion: completion
        )
    }

    static func terminateInBackground(
        _ request: TerminationRequest,
        completion: @escaping @Sendable () -> Void
    ) {
        queue.async {
            terminateAndWait(request)
            completion()
        }
    }
}

/// Gemeinsamer Besitzvertrag für Konvertierungs- und Importprozesse. Beide
/// Kontexte starten einen Prozess atomar gegenüber ihrem jeweiligen Abbruch und
/// entfernen ihn nach dem begrenzten Pipe-Join wieder aus ihrer Besitzliste.
protocol ToolProcessContext: AnyObject, Sendable {
    var isCancelled: Bool { get }
    func run(_ process: Process) throws -> Bool
    func unregister(_ process: Process)
}

/// Liest eine Prozess-Pipe auf genau einer seriellen Queue bis EOF. `waitUntilEOF`
/// ist der Join: Danach läuft garantiert kein Callback mehr und der vollständige
/// Fehlertext steht fest. Das verhindert verspätete Fortschrittsereignisse aus
/// einer bereits abgeschlossenen Kodierphase.
final class ProcessPipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "com.hoerbuchkloeppler.pipe-reader")
    private let completion = DispatchGroup()
    private let stateLock = NSLock()
    private var started = false
    private var stopRequested = false
    private var output = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func start(onChunk: @escaping @Sendable (Data) -> Void = { _ in }) {
        stateLock.lock()
        precondition(!started, "ProcessPipeReader darf nur einmal gestartet werden")
        started = true
        completion.enter()
        stateLock.unlock()
        queue.async { [self] in
            let descriptor = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                stateLock.lock()
                let shouldStop = stopRequested
                stateLock.unlock()
                if shouldStop { break }

                var candidate = pollfd(
                    fd: descriptor,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                )
                let pollResult = Darwin.poll(&candidate, 1, 50)
                if pollResult == 0 { continue }
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    break
                }
                let count = buffer.withUnsafeMutableBytes { storage in
                    Darwin.read(descriptor, storage.baseAddress, storage.count)
                }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    break
                }
                let chunk = Data(buffer.prefix(count))
                output.append(chunk)
                onChunk(chunk)
            }
            completion.leave()
        }
    }

    /// Wartet normalerweise bis EOF. Bei einem begrenzten Join beendet die
    /// Leser-Queue ihre `poll`-Schleife selbst; dadurch kann ein fremdes Kind,
    /// das den Pipe-Schreibdeskriptor geerbt hat, den Aufrufer nicht festhalten.
    func waitUntilEOF(
        timeout: TimeInterval? = nil,
        onTimeout: () -> Void = {}
    ) -> Data {
        stateLock.lock()
        let hasStarted = started
        stateLock.unlock()
        precondition(hasStarted, "ProcessPipeReader muss vor dem Warten gestartet werden")
        if let timeout {
            let bounded = timeout.isFinite ? max(0, timeout) : 1
            if completion.wait(timeout: .now() + bounded) == .timedOut {
                onTimeout()
                stateLock.lock()
                stopRequested = true
                stateLock.unlock()
                completion.wait()
            }
        } else {
            completion.wait()
        }
        return queue.sync { output }
    }
}

enum CapturedProcessResult: Sendable {
    case completed(status: Int32, output: Data)
    case timedOut(output: Data)
    case cancelled(output: Data)
    case failed(String)
}

extension FFmpegWrapper {
    /// Nur reguläre, ausführbare Dateien sind startfähige Tool-Kandidaten.
    /// Ein gebündeltes Binary ohne x-Bit darf den funktionierenden PATH-Fallback
    /// nicht verdecken. Symlinks werden vor der Prüfung aufgelöst:
    /// `attributesOfItem` folgt ihnen nicht und meldet `.typeSymbolicLink` statt
    /// `.typeRegular` — die üblichen Homebrew-/MacPorts-Symlinks (z.B.
    /// `/opt/homebrew/bin/ffmpeg` → `../Cellar/…`) fielen sonst durch.
    public static func isUsableExecutable(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: resolved.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            return false
        }
        return true
    }

    static func resolveBinaryURL(name: String, bundledURL: URL?, pathEnvironment: String?, fallbackPaths: [String]) -> URL? {
        var candidates: [URL] = []
        if let bundledURL { candidates.append(bundledURL) }
        if let pathEnvironment {
            candidates += pathEnvironment.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent(name)
            }
        }
        candidates += fallbackPaths.map { URL(fileURLWithPath: $0) }
        for candidate in candidates where isUsableExecutable(candidate) {
            // Nicht den später veränderbaren Symlink starten, sondern genau das
            // reguläre Binary, das `isUsableExecutable` geprüft hat.
            return candidate.resolvingSymlinksInPath()
        }
        return nil
    }

    public static func getBinaryURL(name: String) -> URL? {
        let bundledURL = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "bin")
        let fallbackPaths = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/opt/local/bin/\(name)", "/usr/bin/\(name)", "/bin/\(name)"]
        return resolveBinaryURL(
            name: name,
            bundledURL: bundledURL,
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"],
            fallbackPaths: fallbackPaths
        )
    }

    /// Liefert nur dann eine Version, wenn der Prozess wirklich startet,
    /// erfolgreich endet und eine nichtleere Ausgabe liefert.
    public static func toolVersion(name: String) -> (url: URL, version: String)? {
        guard let url = getBinaryURL(name: name), let version = toolVersion(at: url, name: name) else { return nil }
        return (url, version)
    }

    static func toolVersion(at url: URL, name: String) -> String? {
        guard isUsableExecutable(url) else { return nil }
        let result = runCapturedProcess(
            executableURL: url,
            arguments: name == "mediainfo" ? ["--Version"] : ["-version"],
            timeout: 5
        )
        guard case .completed(let status, let data) = result,
              status == 0,
              let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { return nil }
        let parts = output.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        if let index = parts.firstIndex(where: { $0.lowercased() == "version" }),
           index + 1 < parts.count {
            return parts[index + 1].replacingOccurrences(of: ",", with: "")
        }
        if name == "mediainfo",
           let version = parts.first(where: { $0.hasPrefix("v") && $0.contains(".") }) {
            return version
        }
        return parts.first
    }

    static func runCapturedProcess(
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
        let reader = ProcessPipeReader(handle: pipe.fileHandleForReading)
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
            process.waitUntilExit()
            // Auch kurze Hilfsaufrufe dürfen keinen vom Wrapper abgekoppelten
            // Nachkommen im eigenen Prozessbaum zurücklassen. Der aufrufende
            // Pfad braucht hier keinen eigenen Fehlerfall: Seine Ausgabe bleibt
            // verwertbar, nachdem der fremde Rest sicher beendet wurde.
            ProcessTerminator.terminateRemainingOwnedGroup(process)
            // Ein bereits beendeter direkter Prozess kann einen Nachkommen mit
            // geerbtem stdout hinterlassen. Dessen offener Schreibdeskriptor darf
            // den informativen Versions-/MediaInfo-Aufruf nicht endlos blockieren.
            let output = reader.waitUntilEOF(timeout: 0.25) {
                // Der direkte Prozess kann bereits beendet sein, während ein
                // Nachkomme seine Pipe geerbt hat. Dann gehört auch dieser Rest
                // zur aufgezeichneten Werkzeug-Prozessgruppe.
                ProcessTerminator.terminateAndWait([process])
            }
            if context?.isCancelled == true { return .cancelled(output: output) }
            if timedOut { return .timedOut(output: output) }
            return .completed(status: process.terminationStatus, output: output)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
