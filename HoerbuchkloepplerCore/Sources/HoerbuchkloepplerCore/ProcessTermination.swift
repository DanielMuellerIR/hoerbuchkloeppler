import Foundation
import Darwin
import os

struct ProcessDeadline {
    private let expiresAt: UInt64

    init(seconds: TimeInterval) {
        let bounded = seconds.isFinite ? min(max(0, seconds), 86_400) : 0
        let nanoseconds = UInt64(bounded * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        let sum = now.addingReportingOverflow(nanoseconds)
        expiresAt = sum.overflow ? UInt64.max : sum.partialValue
    }

    var hasExpired: Bool { DispatchTime.now().uptimeNanoseconds >= expiresAt }

    /// Kurze Intervalle lassen die Leser auch zwischen zwei Werkzeugausgaben abbrechen.
    var nextPollMilliseconds: Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < expiresAt else { return 0 }
        let remaining = min(expiresAt - now, 50_000_000)
        return Int32((remaining + 999_999) / 1_000_000)
    }
}

enum ProcessPipeRead {
    case retry
    case endOfFile
    case failed
    case bytes(Int)

    static func poll(
        descriptor: Int32,
        timeoutMilliseconds: Int32 = 50,
        buffer: inout [UInt8]
    ) -> Self {
        var candidate = pollfd(
            fd: descriptor,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        let readiness = Darwin.poll(&candidate, 1, timeoutMilliseconds)
        if readiness == 0 { return .retry }
        if readiness < 0 { return errno == EINTR ? .retry : .failed }
        let count = buffer.withUnsafeMutableBytes { storage in
            Darwin.read(descriptor, storage.baseAddress, storage.count)
        }
        if count == 0 { return .endOfFile }
        if count < 0 { return errno == EINTR || errno == EAGAIN ? .retry : .failed }
        return .bytes(count)
    }
}

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
    private static let ownedGroups = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: pid_t]())

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
        let identifier = ObjectIdentifier(process)
        ownedGroups.withLock { $0[identifier] = pid }
    }

    static func forgetOwnedProcessGroup(_ process: Process) {
        let identifier = ObjectIdentifier(process)
        _ = ownedGroups.withLock { $0.removeValue(forKey: identifier) }
    }

    private static func ownedGroup(for process: Process) -> pid_t? {
        let identifier = ObjectIdentifier(process)
        return ownedGroups.withLock { $0[identifier] }
    }

    /// Wartet höchstens `seconds` darauf, dass `isPending()` falsch wird, und
    /// prüft dabei im 10-Millisekunden-Takt. Liefert `true`, wenn die Bedingung
    /// vor Ablauf der Frist erfüllt war.
    @discardableResult
    static func wait(
        upTo seconds: TimeInterval,
        while isPending: () -> Bool
    ) -> Bool {
        let deadline = ProcessDeadline(seconds: seconds)
        while isPending(), !deadline.hasExpired {
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

    static func hasRemainingOwnedGroup(_ process: Process) -> Bool {
        guard !process.isRunning, let group = ownedGroup(for: process) else { return false }
        return groupIsRunning(group)
    }

    /// Nach dem Exit des direkten Werkzeugprozesses darf seine besessene
    /// Prozessgruppe keine Nachkommen mehr enthalten. Ein Wrapper könnte sonst
    /// den eigentlichen Encoder im Hintergrund weiterlaufen lassen, während die
    /// bereits teilweise geschriebene Datei als erfolgreich übernommen wird.
    /// Der Rückgabewert sagt, ob ein solcher Rest gefunden und beendet wurde.
    @discardableResult
    static func terminateRemainingOwnedGroup(_ process: Process) -> Bool {
        guard hasRemainingOwnedGroup(process) else { return false }
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
    private var stoppedBeforeEOF = false
    private var output = Data()
    private let maximumBytes: Int
    private let requiresCompleteOutput: Bool
    private var exceeded = false
    private var readFailed = false

    var exceededOutputLimit: Bool { queue.sync { exceeded } }
    var failedToReadOutput: Bool { queue.sync { readFailed } }

    /// Wahr, wenn der begrenzte Join abgelaufen ist, bevor die Pipe EOF
    /// meldete. Die gelesene Ausgabe ist dann still gekürzt — ohne dieses
    /// Merkmal sähe sie für den Aufrufer aus wie eine vollständige.
    var joinTimedOut: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stoppedBeforeEOF
    }

    init(handle: FileHandle, maximumBytes: Int = 256 * 1024, requiresCompleteOutput: Bool = false) {
        self.handle = handle
        self.maximumBytes = max(1, maximumBytes)
        self.requiresCompleteOutput = requiresCompleteOutput
    }

    func start(onChunk: @escaping @Sendable (Data) -> Void = { _ in }) {
        start(state: ()) { _, data in onChunk(data) }
    }

    func start<State: Sendable>(
        state initialState: State,
        onChunk: @escaping @Sendable (inout State, Data) -> Void
    ) {
        stateLock.lock()
        precondition(!started, "ProcessPipeReader darf nur einmal gestartet werden")
        started = true
        completion.enter()
        stateLock.unlock()
        queue.async { [self] in
            defer { completion.leave() }
            let descriptor = handle.fileDescriptor
            var state = initialState
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                stateLock.lock()
                let shouldStop = stopRequested
                stateLock.unlock()
                if shouldStop { break }

                let count: Int
                switch ProcessPipeRead.poll(descriptor: descriptor, buffer: &buffer) {
                case .retry: continue
                case .endOfFile: return
                case .failed:
                    readFailed = true
                    return
                case .bytes(let bytes): count = bytes
                }
                let chunk = Data(buffer.prefix(count))
                // Fortschritt erhält weiterhin jedes Byte; nur die gespeicherte Diagnose ist begrenzt.
                if requiresCompleteOutput {
                    let remaining = max(0, maximumBytes - output.count)
                    output.append(chunk.prefix(remaining))
                    if chunk.count > remaining { exceeded = true }
                } else {
                    output.append(chunk)
                    if output.count > maximumBytes {
                        output.removeFirst(output.count - maximumBytes)
                        exceeded = true
                    }
                }
                onChunk(&state, chunk)
            }
        }
    }

    /// Wartet normalerweise bis EOF. Bei einem begrenzten Join beendet die
    /// Leser-Queue ihre `poll`-Schleife selbst; dadurch kann ein fremdes Kind,
    /// das den Pipe-Schreibdeskriptor geerbt hat, den Aufrufer nicht festhalten.
    /// Dass dabei gekürzt wurde, meldet danach `joinTimedOut` — ein Aufräum-
    /// Rückruf half an dieser Stelle nichts: Der direkte Prozess ist längst
    /// beendet und seine Prozessgruppe schon terminiert, festhalten kann nur
    /// noch ein Nachkomme außerhalb der Gruppe.
    func waitUntilEOF(timeout: TimeInterval? = nil) -> Data {
        stateLock.lock()
        let hasStarted = started
        stateLock.unlock()
        precondition(hasStarted, "ProcessPipeReader muss vor dem Warten gestartet werden")
        if let timeout {
            let bounded = timeout.isFinite ? max(0, timeout) : 1
            if completion.wait(timeout: .now() + bounded) == .timedOut {
                stateLock.lock()
                stopRequested = true
                stoppedBeforeEOF = true
                stateLock.unlock()
                completion.wait()
            }
        } else {
            completion.wait()
        }
        return queue.sync {
            if exceeded && !requiresCompleteOutput {
                return Data("[Diagnose gekürzt; letzte \(maximumBytes) Bytes]\n".utf8) + output
            }
            return output
        }
    }
}
