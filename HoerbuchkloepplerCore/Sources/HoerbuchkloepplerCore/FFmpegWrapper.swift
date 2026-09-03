import Foundation
import AVFoundation
import CoreMedia
import ImageIO
import Darwin

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

public struct ConversionPlan: Sendable {
    public let groups: [[AudioFile]]
    public let outputURLs: [URL]
    let outputSnapshots: [OutputDestinationSnapshot]
    let outputDirectorySnapshots: [OutputDestinationSnapshot]
    let inputSnapshots: [String: OutputDestinationSnapshot]

    /// Ziele, deren Verzeichniseintrag bei der Planung bereits existierte.
    /// Anders als `FileManager.fileExists` folgt diese Auskunft Symlinks nicht;
    /// deshalb verlangt auch ein gebrochener Ziel-Symlink eine Bestätigung.
    public var outputURLsRequiringOverwriteConfirmation: [URL] {
        zip(outputURLs, outputSnapshots).compactMap { url, snapshot in
            if case .missing = snapshot { return nil }
            return url
        }
    }
}

/// Identifiziert genau einen Verzeichniseintrag. Neben Inode und Volume werden
/// Größe sowie Änderungs-/Statuszeit festgehalten, damit auch eine in-place
/// geänderte Zieldatei nicht mehr als die vom Nutzer bestätigte Datei gilt.
struct FileSystemIdentity: Codable, Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let size: off_t
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusSeconds: Int64
    let statusNanoseconds: Int64

    init(stat information: stat) {
        device = information.st_dev
        inode = information.st_ino
        mode = information.st_mode
        size = information.st_size
        modificationSeconds = Int64(information.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(information.st_mtimespec.tv_nsec)
        statusSeconds = Int64(information.st_ctimespec.tv_sec)
        statusNanoseconds = Int64(information.st_ctimespec.tv_nsec)
    }

    /// Ein atomarer Rename aktualisiert auf manchen Volumes die Statuszeit des
    /// verschobenen Eintrags. Für die Prüfung NACH `RENAME_SWAP` zählen deshalb
    /// Inode, Volume, Typ, Größe und Inhalts-Änderungszeit; die strengere
    /// Vorprüfung vergleicht weiterhin alle Felder über `Equatable`.
    func matchesDisplacedEntry(_ other: FileSystemIdentity) -> Bool {
        device == other.device
            && inode == other.inode
            && mode == other.mode
            && size == other.size
            && modificationSeconds == other.modificationSeconds
            && modificationNanoseconds == other.modificationNanoseconds
    }

    /// Verzeichnisgröße und Zeitstempel ändern sich bei jedem Kind-Eintrag.
    /// Für den Besitz eines Verzeichniseintrags sind deshalb nur Volume, Inode
    /// und der unveränderte Dateityp stabil.
    func matchesDirectoryEntry(_ other: FileSystemIdentity) -> Bool {
        device == other.device
            && inode == other.inode
            && mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && other.mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    /// Inhalt und Zeitstempel einer ffmpeg-Ausgabedatei ändern sich während
    /// der Konvertierung. Volume, Inode und Dateityp müssen dagegen vom
    /// exklusiven Anlegen bis zum Commit unverändert bleiben.
    func matchesRegularFileEntry(_ other: FileSystemIdentity) -> Bool {
        device == other.device
            && inode == other.inode
            && mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && other.mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }
}

/// Laufzeitnachweis für genau die exklusiv angelegte Staging-Datei. Auf
/// Volumes ohne Extended Attributes bleibt der Inode-Nachweis nutzbar; nur eine
/// spätere Altlastenbereinigung nach einem Prozessabsturz entfällt dort.
struct StagingOwnership: Sendable {
    let identity: FileSystemIdentity
    let ownerPID: pid_t
    let hasPersistentMarker: Bool
    let protectedDirectory: URL?
    let protectedDirectoryIdentity: FileSystemIdentity?

    var cleanupEntryRecord: CleanupEntryRecord {
        CleanupEntryRecord(
            identity: identity,
            filename: protectedDirectory == nil ? "entry" : "entry.m4b",
            stableIdentityOnly: true
        )
    }
}

struct CleanupEntryRecord: Codable {
    let identity: FileSystemIdentity
    let filename: String
    let stableIdentityOnly: Bool
    let alternateIdentity: FileSystemIdentity?
    let alternateStableIdentityOnly: Bool?

    init(
        identity: FileSystemIdentity,
        filename: String,
        stableIdentityOnly: Bool,
        alternateIdentity: FileSystemIdentity? = nil,
        alternateStableIdentityOnly: Bool? = nil
    ) {
        self.identity = identity
        self.filename = filename
        self.stableIdentityOnly = stableIdentityOnly
        self.alternateIdentity = alternateIdentity
        self.alternateStableIdentityOnly = alternateStableIdentityOnly
    }

    func matches(_ current: FileSystemIdentity) -> Bool {
        let primaryMatches = stableIdentityOnly
            ? identity.matchesRegularFileEntry(current)
            : identity.matchesDisplacedEntry(current)
        guard !primaryMatches, let alternateIdentity else {
            return primaryMatches
        }
        return alternateStableIdentityOnly == true
            ? alternateIdentity.matchesRegularFileEntry(current)
            : alternateIdentity.matchesDisplacedEntry(current)
    }
}

final class StagingOutputHandle: @unchecked Sendable {
    let url: URL
    let ownership: StagingOwnership
    let descriptor: Int32

    init(url: URL, ownership: StagingOwnership, descriptor: Int32) {
        self.url = url
        self.ownership = ownership
        self.descriptor = descriptor
    }

    deinit {
        _ = Darwin.close(descriptor)
    }

    func processInputHandle() -> FileHandle {
        FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    }
}

enum OutputDestinationSnapshot: Equatable, Sendable {
    case missing
    case existing(FileSystemIdentity)
    case inaccessible(errno: Int32)
}

enum ConversionOutputError: LocalizedError {
    case destinationChanged(URL)
    case destinationInaccessible(URL, Int32)
    case destinationDirectoryChanged(URL)
    case destinationDirectoryInaccessible(URL, Int32)
    case destinationIsDirectory(URL)
    case destinationAliasesInput(URL, URL)
    case destinationBusy(URL)
    case lockFailed(URL, Int32)
    case restoreFailed(URL, recoveryURL: URL?, errno: Int32)
    case stagingChanged(URL)
    case sourceChanged(URL)
    case sourceInaccessible(URL, Int32)

    var errorDescription: String? {
        switch self {
        case .destinationChanged(let url):
            return "Die Zieldatei wurde seit der Bestätigung verändert: \(url.path)"
        case .destinationInaccessible(let url, let number):
            return "Die Zieldatei kann nicht sicher geprüft werden: \(url.path) (\(Self.reason(number)))"
        case .destinationDirectoryChanged(let url):
            return "Der Ausgabeordner wurde seit der Planung ersetzt: \(url.path)"
        case .destinationDirectoryInaccessible(let url, let number):
            return "Der Ausgabeordner kann nicht sicher geprüft werden: \(url.path) (\(Self.reason(number)))"
        case .destinationIsDirectory(let url):
            return "Der Zielpfad ist ein Ordner und wird nicht ersetzt: \(url.path)"
        case .destinationAliasesInput(let output, let input):
            return "Die Ausgabe verweist auf eine Eingabedatei: \(output.path) → \(input.path)"
        case .destinationBusy(let url):
            return "Ein anderer Hörbuchklöppler-Lauf verwendet bereits dieses Ziel: \(url.path)"
        case .lockFailed(let url, let number):
            return "Das Ziel konnte nicht exklusiv reserviert werden: \(url.path) (\(Self.reason(number)))"
        case .restoreFailed(let url, let recoveryURL, let number):
            let recovery = recoveryURL.map {
                " Der verdrängte Eintrag bleibt zur manuellen Wiederherstellung unter \($0.path) erhalten."
            } ?? ""
            return "Die zwischenzeitlich geänderte Zieldatei konnte nicht zurückgetauscht werden: \(url.path) (\(Self.reason(number))).\(recovery)"
        case .stagingChanged(let url):
            return "Die temporäre Ausgabedatei wurde während der Übernahme ausgetauscht und bleibt unangetastet: \(url.path)"
        case .sourceChanged(let url):
            return "Eine Eingabedatei wurde seit der Planung verändert: \(url.path)"
        case .sourceInaccessible(let url, let number):
            return "Eine Eingabedatei kann nicht sicher gelesen werden: \(url.path) (\(Self.reason(number)))"
        }
    }

    private static func reason(_ number: Int32) -> String {
        String(cString: strerror(number))
    }
}

/// Hält pro Ziel eine prozessübergreifende `fcntl`-Sperre. Die kleine versteckte
/// Lock-Datei bleibt absichtlich liegen: Würde ein Prozess sie beim Freigeben
/// löschen, könnte ein zweiter Prozess schon einen neuen Inode sperren, während
/// ein dritter noch den alten hält.
final class OutputLeaseSet: @unchecked Sendable {
    private var descriptors: [Int32]
    private let canonicalPaths: [String]

    init(descriptors: [Int32], canonicalPaths: [String]) {
        self.descriptors = descriptors
        self.canonicalPaths = canonicalPaths
    }

    deinit {
        for descriptor in descriptors {
            FFmpegWrapper.releaseOutputLock(descriptor)
        }
        FFmpegWrapper.releaseInProcessOutputPaths(canonicalPaths)
    }
}

public enum ConversionCancellationOutcome: Sendable {
    case noActiveConversion
    case cancelled
    case rejected
}

public enum ConversionStartResult: Equatable, Sendable {
    case started
    case rejected(String)
}

/// Laufbezogener Besitz aller Prozesse und temporären Dateien. Dadurch kann ein
/// Fenster nur seinen eigenen Lauf abbrechen; ein zweites Fenster bleibt
/// unangetastet. Die Sperre schließt außerdem das Rennen zwischen Start und
/// Abbruch eines Prozesses.
final class ConversionContext: ToolProcessContext, @unchecked Sendable {
    private struct DisplacedOutputResource {
        let identity: FileSystemIdentity
        let stagingOwnership: StagingOwnership?
    }

    let id = UUID()

    private let lock = NSCondition()
    private let log: @Sendable (UUID, String) -> Void
    private var cancelled = false
    private var finished = false
    private var cancellationCleanupInProgress = false
    private var processes = Set<Process>()
    private var tempDirectories: [URL: FileSystemIdentity] = [:]
    private var stagedOutputs: [URL: StagingOwnership] = [:]
    private var residualStagedOutputs: [URL: StagingOwnership] = [:]
    private var displacedOutputs: [URL: DisplacedOutputResource] = [:]

    init(log: @escaping @Sendable (UUID, String) -> Void = { _, _ in }) {
        self.log = log
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Startet und registriert den Prozess atomar gegenüber `cancel()`. Ein
    /// bereits gewonnener Abbruch verhindert den Start vollständig.
    func run(_ process: Process) throws -> Bool {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return false
        }
        processes.insert(process)
        do {
            try process.run()
            ProcessTerminator.recordOwnedProcessGroup(process)
            lock.unlock()
            return true
        } catch {
            processes.remove(process)
            lock.unlock()
            throw error
        }
    }

    func unregister(_ process: Process) {
        lock.lock()
        processes.remove(process)
        lock.unlock()
        ProcessTerminator.forgetOwnedProcessGroup(process)
    }

    func registerTempDirectory(_ url: URL) {
        guard let identity = FFmpegWrapper.fileSystemIdentity(at: url, followSymlink: false),
              identity.mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return }
        lock.lock()
        tempDirectories[url] = identity
        let shouldRemove = cancelled
        lock.unlock()
        if shouldRemove {
            FFmpegWrapper.removeOwnedTempDirectory(url, expectedIdentity: identity)
        }
    }

    func removeTempDirectory(_ url: URL) {
        lock.lock()
        let identity = tempDirectories.removeValue(forKey: url)
        lock.unlock()
        if let identity {
            FFmpegWrapper.removeOwnedTempDirectory(url, expectedIdentity: identity)
        }
    }

    @discardableResult
    static func unlinkStagedOutput(
        _ url: URL,
        expectedOwnership: StagingOwnership? = nil,
        log: @Sendable (String) -> Void = { _ in }
    ) -> Bool {
        if let expectedOwnership,
           expectedOwnership.protectedDirectory != nil {
            return FFmpegWrapper.removeProtectedStagingOutput(
                url,
                ownership: expectedOwnership,
                log: log
            )
        }
        return FFmpegWrapper.removeOwnedStagedOutput(
            url,
            expectedOwnership: expectedOwnership,
            log: log
        )
    }

    func registerStagedOutput(
        _ url: URL,
        ownership suppliedOwnership: StagingOwnership? = nil
    ) {
        guard let ownership = suppliedOwnership
            ?? FFmpegWrapper.currentStagingOwnership(at: url) else { return }
        lock.lock()
        stagedOutputs[url] = ownership
        let shouldRemove = cancelled
        lock.unlock()
        if shouldRemove {
            let removed = ConversionContext.unlinkStagedOutput(
                url,
                expectedOwnership: ownership
            ) { [id, log] message in
                log(id, message)
            }
            lock.lock()
            stagedOutputs.removeValue(forKey: url)
            if !removed { residualStagedOutputs[url] = ownership }
            lock.unlock()
        }
    }

    func unregisterStagedOutput(_ url: URL) {
        lock.lock()
        stagedOutputs.removeValue(forKey: url)
        residualStagedOutputs.removeValue(forKey: url)
        lock.unlock()
    }

    func completeStagedOutput(_ url: URL) {
        lock.lock()
        let ownership = stagedOutputs.removeValue(forKey: url)
            ?? residualStagedOutputs.removeValue(forKey: url)
        lock.unlock()
        if let ownership {
            cleanupProtectedStagingContainer(url, ownership: ownership)
        }
    }

    private func cleanupProtectedStagingContainer(
        _ url: URL,
        ownership: StagingOwnership
    ) {
        guard !FFmpegWrapper.removeEmptyProtectedStagingDirectory(
            ownership: ownership
        ) else { return }
        lock.lock()
        residualStagedOutputs[url] = ownership
        lock.unlock()
    }

    func discardStagedOutput(_ url: URL) {
        lock.lock()
        let ownership = stagedOutputs.removeValue(forKey: url)
        let alreadyCancelled = cancelled
        lock.unlock()
        // Nach einem gewonnenen Abbruch hat `cancel()` die Besitzliste geleert
        // und räumt genau diesen Eintrag mit der einzig gültigen Ownership auf.
        // Ein zweiter Versuch ohne Ownership könnte ihn nicht entfernen und
        // würde die noch laufende Bereinigung fälschlich als liegengebliebene
        // Datei melden.
        guard ownership != nil || !alreadyCancelled else { return }
        let removed = ConversionContext.unlinkStagedOutput(
            url,
            expectedOwnership: ownership
        ) { [id, log] message in
            log(id, message)
        }
        if !removed, let ownership {
            lock.lock()
            residualStagedOutputs[url] = ownership
            lock.unlock()
        }
    }

    /// Fehler nach einem atomaren Rollback können bedeuten, dass unter der
    /// Staging-URL inzwischen ein fremder Eintrag liegt. Nur eindeutig eigene
    /// Fehlerpfade dürfen die markierte Partial-Datei entfernen.
    func handleCommitFailure(_ error: Error, stagedURL: URL) {
        if case ConversionOutputError.restoreFailed = error {
            unregisterStagedOutput(stagedURL)
        } else if case ConversionOutputError.stagingChanged = error {
            unregisterStagedOutput(stagedURL)
        } else {
            discardStagedOutput(stagedURL)
        }
    }

    func registerDisplacedOutput(
        _ url: URL,
        expectedIdentity: FileSystemIdentity,
        stagingOwnership suppliedOwnership: StagingOwnership? = nil
    ) {
        lock.lock()
        let registeredOwnership = stagedOutputs.removeValue(forKey: url)
        let stagingOwnership = suppliedOwnership ?? registeredOwnership
        displacedOutputs[url] = DisplacedOutputResource(
            identity: expectedIdentity,
            stagingOwnership: stagingOwnership
        )
        let shouldRemove = cancelled
        lock.unlock()
        if shouldRemove {
            let removed = FFmpegWrapper.removeDisplacedOutput(
                url,
                expectedIdentity: expectedIdentity,
                cleanupParent: stagingOwnership?.protectedDirectory?
                    .deletingLastPathComponent()
            ) { [id, log] message in
                log(id, message)
            }
            if removed {
                if let stagingOwnership {
                    cleanupProtectedStagingContainer(
                        url,
                        ownership: stagingOwnership
                    )
                }
                lock.lock()
                displacedOutputs.removeValue(forKey: url)
                lock.unlock()
            }
        }
    }

    /// Wiederholt am normalen Laufende die Bereinigung einer verdrängten
    /// Altdatei, deren erster `unlink` fehlgeschlagen ist. Der Eintrag bleibt bis
    /// zum bestätigten Erfolg registriert und wird auch bei einem Abbruch erneut
    /// versucht; ein verbleibender Fehler steht damit sichtbar im Log.
    func cleanupResidualStagedOutputs() {
        lock.lock()
        let stagedResiduals = residualStagedOutputs
        let residuals = displacedOutputs
        lock.unlock()
        for (url, ownership) in stagedResiduals {
            let removed = ConversionContext.unlinkStagedOutput(
                url,
                expectedOwnership: ownership
            ) { [id, log] message in
                log(id, message)
            }
            if removed {
                lock.lock()
                residualStagedOutputs.removeValue(forKey: url)
                lock.unlock()
            }
        }
        for (url, resource) in residuals {
            let removed = FFmpegWrapper.removeDisplacedOutput(
                url,
                expectedIdentity: resource.identity,
                cleanupParent: resource.stagingOwnership?.protectedDirectory?
                    .deletingLastPathComponent()
            ) { [id, log] message in
                log(id, message)
            }
            if removed {
                if let ownership = resource.stagingOwnership {
                    cleanupProtectedStagingContainer(
                        url,
                        ownership: ownership
                    )
                }
                lock.lock()
                displacedOutputs.removeValue(forKey: url)
                lock.unlock()
            }
        }
    }

    /// Führt den atomaren Commit nur aus, solange noch kein Abbruch gewonnen hat.
    /// Beim letzten Ziel wird der Lauf in derselben Sperre abgeschlossen; ein
    /// danach eintreffender Cancel darf die bereits fertige Ausgabe nicht mehr
    /// fälschlich als abgebrochen melden.
    func performCommit(isLastOutput: Bool, _ mutation: () throws -> Void) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        try mutation()
        if isLastOutput { finished = true }
        return true
    }

    /// Gibt `true` zurück, wenn dieser Aufruf den Lauf tatsächlich abgebrochen
    /// hat. Ein bereits mit dem letzten atomaren Commit abgeschlossener Lauf
    /// ignoriert einen verspäteten Cancel.
    @discardableResult
    func cancel(onAccepted: @Sendable () -> Void = {}) -> Bool {
        lock.lock()
        guard !finished, !cancelled else {
            lock.unlock()
            return false
        }
        cancelled = true
        cancellationCleanupInProgress = true
        // Der Queue-Eintrag gehört atomar zum gewonnenen Abbruch. So kann der
        // Worker keinen Abschluss zwischen Statuswechsel und Meldung einreihen.
        onAccepted()
        let ownedProcesses = processes
        // Den Prozessgruppen-Besitz unter derselben Sperre festhalten wie die
        // Prozessliste. Ein Worker darf danach `unregister` ausführen, ohne dem
        // bereits angenommenen Abbruch seine Nachkommen wieder zu entziehen.
        let terminationRequest = ProcessTerminator.makeTerminationRequest(
            for: Array(ownedProcesses)
        )
        let ownedDirectories = tempDirectories
        let ownedStagedOutputs = stagedOutputs.merging(
            residualStagedOutputs,
            uniquingKeysWith: { current, _ in current }
        )
        let ownedDisplacedOutputs = displacedOutputs
        processes.removeAll()
        tempDirectories.removeAll()
        stagedOutputs.removeAll()
        residualStagedOutputs.removeAll()
        displacedOutputs.removeAll()
        lock.unlock()

        let finishCleanup: @Sendable () -> Void = { [self] in
            for (directory, identity) in ownedDirectories {
                FFmpegWrapper.removeOwnedTempDirectory(
                    directory,
                    expectedIdentity: identity
                )
            }
            for (output, ownership) in ownedStagedOutputs {
                let removed = ConversionContext.unlinkStagedOutput(
                    output,
                    expectedOwnership: ownership
                ) { [id, log] message in
                    log(id, message)
                }
                if !removed {
                    lock.lock()
                    residualStagedOutputs[output] = ownership
                    lock.unlock()
                }
            }
            for (output, resource) in ownedDisplacedOutputs {
                let removed = FFmpegWrapper.removeDisplacedOutput(
                    output,
                    expectedIdentity: resource.identity,
                    cleanupParent: resource.stagingOwnership?
                        .protectedDirectory?.deletingLastPathComponent()
                ) { [id, log] message in
                    log(id, message)
                }
                if removed {
                    if let ownership = resource.stagingOwnership {
                        cleanupProtectedStagingContainer(
                            output,
                            ownership: ownership
                        )
                    }
                } else {
                    lock.lock()
                    displacedOutputs[output] = resource
                    lock.unlock()
                }
            }

            lock.lock()
            cancellationCleanupInProgress = false
            lock.broadcast()
            lock.unlock()
        }
        if !ownedProcesses.isEmpty {
            ProcessTerminator.terminateInBackground(
                terminationRequest,
                completion: finishCleanup
            )
        } else {
            finishCleanup()
        }
        return true
    }

    /// Reiht den terminalen Worker-Event erst nach einer bereits laufenden
    /// Abbruchbereinigung ein. Ohne diese Barriere könnte der Main Actor den
    /// Lauf beenden und nachfolgende Bereinigungswarnungen als veraltet löschen.
    func finishAfterCancellationCleanup(
        _ action: @Sendable (Bool) -> Void
    ) {
        lock.lock()
        while cancellationCleanupInProgress {
            lock.wait()
        }
        finished = true
        let wasCancelled = cancelled
        lock.unlock()
        action(wasCancelled)
    }
}

/// Unveränderlicher Laufzeit-Snapshot für den ffmpeg-Worker. Der Worker liest
/// dadurch nie nebenläufig aus dem Main-Actor-Modell `ConversionSession`.
private struct ConversionJob: Sendable {
    let plan: ConversionPlan
    // Der Worker muss die Sperren bis zum letzten Commit beziehungsweise bis
    // zum vollständigen Abbruch halten. Die Eigenschaft wird nur zur Lebensdauer
    // genutzt; die Deskriptoren selbst bleiben im `OutputLeaseSet` gekapselt.
    let outputLeases: OutputLeaseSet
    let settings: AudioSettings
    let title: String
    let author: String
    let genre: String
    let coverData: Data?
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

/// Behält genug Byte-Kontext, um einen ffmpeg-Zeitwert auch dann zu erkennen,
/// wenn die Pipe ihn zwischen zwei Chunks trennt. Bei mehreren Statuszeilen
/// gewinnt der neueste statt des ersten Werts.
final class FFmpegProgressParser: @unchecked Sendable {
    private var tail = Data()

    func consume(_ chunk: Data) -> TimeInterval? {
        var combined = tail
        combined.append(chunk)
        let text = String(decoding: combined, as: UTF8.self)
        let result = FFmpegWrapper.extractTimesFromFFmpeg(text).last
            .flatMap(FFmpegWrapper.timeToSeconds)
        tail = Data(combined.suffix(64))
        return result
    }
}

enum CapturedProcessResult: Sendable {
    case completed(status: Int32, output: Data)
    case timedOut(output: Data)
    case cancelled(output: Data)
    case failed(String)
}

private final class ParallelProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var progresses: [Int: Double] = [:]

    func update(index: Int, progress: Double, itemCount: Int) -> Double {
        lock.lock()
        progresses[index] = progress
        let total = progresses.values.reduce(0, +) / Double(max(1, itemCount))
        lock.unlock()
        return total
    }
}

private final class ParallelResults: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String]

    init(count: Int) {
        paths = Array(repeating: "", count: count)
    }

    func store(_ path: String, at index: Int) -> Int {
        lock.lock()
        paths[index] = path
        let finishedCount = paths.lazy.filter { !$0.isEmpty }.count
        lock.unlock()
        return finishedCount
    }

    func completedPaths() -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        return paths.allSatisfy { !$0.isEmpty } ? paths : nil
    }
}

public struct FFmpegWrapper {
    private static let tempOwnerFilename = ".owner-pid"
    private static let cleanupEntryIdentityFilename = ".entry-identity.json"
    private static let stagingOwnerAttribute = "com.hoerbuchkloeppler.staging-owner"
    static let maximumCoverByteCount = 32 * 1024 * 1024
    private static let outputLeaseRegistryLock = NSLock()
    private static nonisolated(unsafe) var leasedOutputPaths = Set<String>()

    static func fileSystemIdentity(
        at url: URL,
        followSymlink: Bool
    ) -> FileSystemIdentity? {
        var information = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return Darwin.fstatat(
                AT_FDCWD,
                path,
                &information,
                followSymlink ? 0 : AT_SYMLINK_NOFOLLOW
            )
        }
        guard result == 0 else { return nil }
        return FileSystemIdentity(stat: information)
    }

    static func captureSnapshot(
        of url: URL,
        followSymlink: Bool = false
    ) -> OutputDestinationSnapshot {
        if let identity = fileSystemIdentity(at: url, followSymlink: followSymlink) {
            return .existing(identity)
        }
        let errorNumber = errno
        return errorNumber == ENOENT || errorNumber == ENOTDIR
            ? .missing
            : .inaccessible(errno: errorNumber)
    }

    @discardableResult
    static func renameEntry(
        from sourceURL: URL,
        to destinationURL: URL,
        flags: UInt32
    ) -> Int32 {
        sourceURL.path.withCString { source in
            destinationURL.path.withCString { destination in
                Darwin.renameatx_np(
                    AT_FDCWD,
                    source,
                    AT_FDCWD,
                    destination,
                    flags
                )
            }
        }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Auf case-insensitiven Volumes müssen Schreibvarianten denselben
    /// Registry- und Lock-Schlüssel erhalten. Die explizite Variante hält die
    /// Normalisierung ohne besonderes Test-Volume prüfbar.
    static func outputLeaseKey(
        for output: URL,
        caseSensitiveNames: Bool? = nil
    ) -> String {
        let path = canonicalPath(output).precomposedStringWithCanonicalMapping
        let parent = output.deletingLastPathComponent()
        let caseSensitive = caseSensitiveNames
            ?? (try? parent.resourceValues(
                forKeys: [.volumeSupportsCaseSensitiveNamesKey]
            ))?.volumeSupportsCaseSensitiveNames
            ?? false
        guard !caseSensitive else { return path }
        return path.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    /// Stabiler Hash für kurze Lock-Dateinamen. Die Sperrdatei liegt im selben
    /// Zielordner; dadurch gelten Zugriffsrechte und Volume-Semantik des Ziels.
    static func outputLockURL(
        for output: URL,
        caseSensitiveNames: Bool? = nil
    ) -> URL {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in outputLeaseKey(
            for: output,
            caseSensitiveNames: caseSensitiveNames
        ).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let name = String(format: ".hoerbuchkloeppler-%016llx.lock", hash)
        return output.deletingLastPathComponent().appendingPathComponent(name)
    }

    static func acquireOutputLeases(for outputs: [URL]) throws -> OutputLeaseSet {
        let uniqueOutputs = Dictionary(
            outputs.map { (outputLeaseKey(for: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { outputLeaseKey(for: $0) < outputLeaseKey(for: $1) }
        let canonicalPaths = uniqueOutputs.map { outputLeaseKey(for: $0) }
        outputLeaseRegistryLock.lock()
        if let busyPath = canonicalPaths.first(where: { leasedOutputPaths.contains($0) }) {
            outputLeaseRegistryLock.unlock()
            let output = uniqueOutputs.first {
                outputLeaseKey(for: $0) == busyPath
            } ?? uniqueOutputs[0]
            throw ConversionOutputError.destinationBusy(output)
        }
        leasedOutputPaths.formUnion(canonicalPaths)
        outputLeaseRegistryLock.unlock()

        var descriptors: [Int32] = []

        func releaseAcquiredDescriptors() {
            for descriptor in descriptors {
                releaseOutputLock(descriptor)
            }
            descriptors.removeAll()
            releaseInProcessOutputPaths(canonicalPaths)
        }

        for output in uniqueOutputs {
            let lockURL = outputLockURL(for: output)
            let descriptor = lockURL.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else {
                    errno = EINVAL
                    return -1
                }
                return Darwin.open(
                    path,
                    O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(0o600)
                )
            }
            guard descriptor >= 0 else {
                let errorNumber = errno
                releaseAcquiredDescriptors()
                throw ConversionOutputError.lockFailed(output, errorNumber)
            }
            var fileLock = flock()
            fileLock.l_type = Int16(F_WRLCK)
            fileLock.l_whence = Int16(SEEK_SET)
            guard Darwin.fcntl(descriptor, F_SETLK, &fileLock) == 0 else {
                let errorNumber = errno
                _ = Darwin.close(descriptor)
                releaseAcquiredDescriptors()
                if errorNumber == EWOULDBLOCK || errorNumber == EAGAIN {
                    throw ConversionOutputError.destinationBusy(output)
                }
                throw ConversionOutputError.lockFailed(output, errorNumber)
            }
            descriptors.append(descriptor)
        }
        return OutputLeaseSet(
            descriptors: descriptors,
            canonicalPaths: canonicalPaths
        )
    }

    /// Gibt eine `fcntl`-Sperre frei und schließt ihren Deskriptor. Der
    /// Rückzug nach einem misslungenen Sperrsatz und das reguläre Ende über
    /// `OutputLeaseSet.deinit` müssen exakt dasselbe tun; sonst bliebe auf einem
    /// der beiden Wege eine Sperre oder ein Deskriptor stehen.
    static func releaseOutputLock(_ descriptor: Int32) {
        var fileLock = flock()
        fileLock.l_type = Int16(F_UNLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        _ = Darwin.fcntl(descriptor, F_SETLK, &fileLock)
        _ = Darwin.close(descriptor)
    }

    /// Öffnet genau den benannten Ordner als Deskriptor. `O_DIRECTORY` weist
    /// eine untergeschobene Datei ab, `O_NOFOLLOW` einen untergeschobenen
    /// Symlink — an dieser Flagkombination hängt die gesamte gebundene
    /// Bereinigung, deshalb steht sie nur an einer Stelle.
    static func openOwnedDirectory(_ url: URL) -> Int32 {
        url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
    }

    /// Entfernt einen leeren Ordnereintrag. Bewusst `rmdir` statt
    /// `removeItem`: Wurde der sichtbare Pfad nach dem gebundenen Leeren
    /// ausgetauscht, bleibt ein Ersatz mit Inhalt stehen, statt rekursiv
    /// gelöscht zu werden.
    @discardableResult
    static func removeEmptyDirectory(_ url: URL) -> Int32 {
        url.withUnsafeFileSystemRepresentation { path in
            path.map(Darwin.rmdir) ?? -1
        }
    }

    static func releaseInProcessOutputPaths(_ paths: [String]) {
        outputLeaseRegistryLock.lock()
        leasedOutputPaths.subtract(paths)
        outputLeaseRegistryLock.unlock()
    }

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

    public static func makeConversionPlan(files: [AudioFile], outputURL: URL, maxDurationHours: Int?) -> ConversionPlan {
        let groups = splitAudioFilesIfNeeded(files, maxDurationHours: maxDurationHours)
        let outputs = groups.indices.map {
            resolveOutputURL(outputURL, groupIndex: $0, splitGroupsCount: groups.count)
        }
        let inputSnapshots = Dictionary(
            files.map {
                let key = canonicalPath($0.url)
                return (key, captureSnapshot(of: $0.url, followSymlink: true))
            },
            uniquingKeysWith: { first, _ in first }
        )
        return ConversionPlan(
            groups: groups,
            outputURLs: outputs,
            outputSnapshots: outputs.map { captureSnapshot(of: $0) },
            outputDirectorySnapshots: outputs.map {
                captureSnapshot(
                    of: $0.deletingLastPathComponent(),
                    followSymlink: true
                )
            },
            inputSnapshots: inputSnapshots
        )
    }

    /// Der Zielname allein reicht bei einer anfangs fehlenden Ausgabedatei
    /// nicht: Ein Dateisynchronisierer kann den Elternordner zwischen Planung
    /// und Konvertierung austauschen. Verzeichnisgröße und Zeitstempel ändern
    /// sich regulär; Volume und Inode binden dagegen den ausgewählten Ordner.
    static func validateOutputDirectorySnapshot(
        for output: URL,
        expected: OutputDestinationSnapshot
    ) throws {
        let directory = output.deletingLastPathComponent()
        let current = captureSnapshot(of: directory, followSymlink: true)
        switch (expected, current) {
        case (.existing(let old), .existing(let new))
            where old.matchesDirectoryEntry(new):
            return
        case (_, .inaccessible(let number)):
            throw ConversionOutputError.destinationDirectoryInaccessible(
                directory,
                number
            )
        case (.inaccessible(let number), _):
            throw ConversionOutputError.destinationDirectoryInaccessible(
                directory,
                number
            )
        default:
            throw ConversionOutputError.destinationDirectoryChanged(directory)
        }
    }

    static func validateInputSnapshots(
        for files: [AudioFile],
        expected: [String: OutputDestinationSnapshot]
    ) throws {
        var checked = Set<String>()
        for file in files {
            let key = canonicalPath(file.url)
            guard checked.insert(key).inserted else { continue }
            let current = captureSnapshot(of: file.url, followSymlink: true)
            guard let planned = expected[key] else {
                throw ConversionOutputError.sourceChanged(file.sourceURL)
            }
            switch (planned, current) {
            case (.existing(let old), .existing(let new)) where old == new:
                continue
            case (_, .inaccessible(let number)):
                throw ConversionOutputError.sourceInaccessible(file.sourceURL, number)
            default:
                throw ConversionOutputError.sourceChanged(file.sourceURL)
            }
        }
    }

    static func validateConversionPlan(_ plan: ConversionPlan) throws {
        guard plan.groups.count == plan.outputURLs.count,
              plan.outputURLs.count == plan.outputSnapshots.count,
              plan.outputURLs.count == plan.outputDirectorySnapshots.count,
              !plan.groups.isEmpty,
              plan.groups.allSatisfy({ !$0.isEmpty }) else {
            throw ConversionOutputError.destinationChanged(
                plan.outputURLs.first ?? URL(fileURLWithPath: "/")
            )
        }
        let files = plan.groups.flatMap { $0 }
        try validateInputSnapshots(for: files, expected: plan.inputSnapshots)

        let inputByPath = Dictionary(
            files.map { (canonicalPath($0.url), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let inputIdentities: [(AudioFile, FileSystemIdentity)] = files.compactMap { file in
            guard case .existing(let identity) = plan.inputSnapshots[canonicalPath(file.url)] else {
                return nil
            }
            return (file, identity)
        }
        var seenOutputs = Set<String>()

        for (index, output) in plan.outputURLs.enumerated() {
            try validateOutputDirectorySnapshot(
                for: output,
                expected: plan.outputDirectorySnapshots[index]
            )
            let outputPath = canonicalPath(output)
            guard seenOutputs.insert(outputPath).inserted else {
                throw ConversionOutputError.destinationChanged(output)
            }
            let planned = plan.outputSnapshots[index]
            let current = captureSnapshot(of: output)
            guard planned == current else {
                if case .inaccessible(let number) = current {
                    throw ConversionOutputError.destinationInaccessible(output, number)
                }
                throw ConversionOutputError.destinationChanged(output)
            }
            if case .inaccessible(let number) = planned {
                throw ConversionOutputError.destinationInaccessible(output, number)
            }
            if case .existing(let identity) = planned,
               identity.mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                throw ConversionOutputError.destinationIsDirectory(output)
            }
            if let input = inputByPath[outputPath] {
                throw ConversionOutputError.destinationAliasesInput(output, input.sourceURL)
            }
            if let outputIdentity = fileSystemIdentity(at: output, followSymlink: true),
               let match = inputIdentities.first(where: {
                   $0.1.device == outputIdentity.device && $0.1.inode == outputIdentity.inode
               }) {
                throw ConversionOutputError.destinationAliasesInput(output, match.0.sourceURL)
            }
        }
    }

    /// Liest nur einen bereits geöffneten regulären Eintrag, begrenzt die
    /// Eingabegröße und prüft danach einen kleinen ImageIO-Decode. `O_NONBLOCK`
    /// verhindert, dass eine nach der Auswahl eingesetzte FIFO den Start hält.
    static func loadCoverSnapshot(
        at url: URL,
        expectedIdentity: FileSystemIdentity? = nil,
        isCancelled: () -> Bool = { false }
    ) -> Data? {
        guard !isCancelled() else { return nil }
        let resolved = url.resolvingSymlinksInPath()
        guard !isCancelled() else { return nil }
        let descriptor = resolved.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_size > 0,
              before.st_size <= off_t(maximumCoverByteCount) else { return nil }
        let openedIdentity = FileSystemIdentity(stat: before)
        if let expectedIdentity, expectedIdentity != openedIdentity { return nil }

        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= maximumCoverByteCount {
            guard !isCancelled() else { return nil }
            let remaining = maximumCoverByteCount + 1 - data.count
            let count = buffer.withUnsafeMutableBytes { storage in
                Darwin.read(
                    descriptor,
                    storage.baseAddress,
                    min(storage.count, remaining)
                )
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            data.append(contentsOf: buffer.prefix(count))
        }

        var after = stat()
        guard data.count <= maximumCoverByteCount,
              data.count == Int(before.st_size),
              Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              !isCancelled(),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard !isCancelled() else { return nil }
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, options) != nil else {
            return nil
        }
        return data
    }

    @MainActor
    static func coverSnapshotForConversion(_ session: ConversionSession) -> Data? {
        session.embeddedCoverData
    }

    @MainActor
    @discardableResult
    public static func convert(
        session: ConversionSession,
        outputURL: URL
    ) -> ConversionStartResult {
        convert(
            session: session,
            plan: makeConversionPlan(
                files: session.audioFiles,
                outputURL: outputURL,
                maxDurationHours: session.settings.maxDurationHours
            )
        )
    }

    @MainActor
    @discardableResult
    public static func convert(
        session: ConversionSession,
        plan: ConversionPlan
    ) -> ConversionStartResult {
        // Ohne Eingabedateien gar nicht erst starten — sonst leere ffmpeg-Liste
        // und Division durch die Gruppengröße bei der Fortschrittsberechnung.
        guard !plan.groups.isEmpty, !plan.groups.flatMap({ $0 }).isEmpty,
              plan.groups.count == plan.outputURLs.count else {
            session.isConverting = false
            session.lastConversionSucceeded = false
            session.conversionStatus = "Keine Dateien"
            session.addLog(
                "❌ Keine Audiodateien zum Konvertieren vorhanden.",
                type: .highlight
            )
            return .rejected("Keine Audiodateien zum Konvertieren vorhanden.")
        }
        let outputLeases: OutputLeaseSet
        do {
            try validateConversionPlan(plan)
            outputLeases = try acquireOutputLeases(for: plan.outputURLs)
        } catch {
            session.isConverting = false
            session.lastConversionSucceeded = false
            session.conversionStatus = "Ausgabe nicht sicher verfügbar"
            session.addLog("❌ \(error.localizedDescription)", type: .highlight)
            return .rejected(error.localizedDescription)
        }
        let plannedFiles = plan.groups.flatMap { $0 }
        let context = session.beginConversionRun()
        let job = ConversionJob(
            plan: plan,
            outputLeases: outputLeases,
            settings: session.settings,
            title: session.title,
            author: session.author,
            genre: session.genre,
            // Ein manuell gewähltes Cover wird ausschließlich aus dem beim
            // Auswählen gelesenen Snapshot kodiert. Der sichtbare Pfad bleibt
            // nur UI-Metadatum und darf den Inhalt später nicht austauschen.
            coverData: coverSnapshotForConversion(session)
        )
        let plannedTotalDuration = plannedFiles.reduce(0) { $0 + $1.duration }
        guard session.isCurrentConversion(context.id) else {
            return .rejected("Ein neuer Konvertierungslauf hat diesen Start ersetzt.")
        }
        session.showOverlay = true
        session.isConverting = true
        session.lastConversionSucceeded = nil
        session.completedOutputURLs = []
        session.conversionStatus = "Konvertierung läuft"
        session.progress = 0.0
        session.eventLogs = []
        session.logString = ""
        session.segmentProgress = [:]
        let totalHours = Int(plannedTotalDuration / 3600)
        let totalMinutes = Int((plannedTotalDuration.truncatingRemainder(dividingBy: 3600)) / 60)
        let durationStr = String(format: "%02d:%02dh", totalHours, totalMinutes)
        let channels = job.settings.isMono ? "Mono" : "Stereo"

        let physicalInputURLs = Set(plannedFiles.map { $0.url.standardizedFileURL })
        var totalSize: Int64 = 0
        for url in physicalInputURLs {
            if let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attr[.size] as? Int64 {
                totalSize += size
            }
        }
        let sizeStr = formatFileSize(totalSize)
        let fileCount = Set(plannedFiles.map { $0.sourceURL.standardizedFileURL }).count

        let titleStr = job.title.isEmpty ? "Unbekannt" : job.title
        let authorStr = job.author.isEmpty ? "Unbekannt" : job.author

        session.addLog("STARTE VORGANG \(titleStr) / \(authorStr), Dauer: \(durationStr)", type: .highlight)
        session.addLog("Eingangsdateien: \(fileCount) Dateien mit insgesamt \(sizeStr)", type: .info)
        session.addLog("Kodierungsparameter: \(channels) \(job.settings.sampleRate) Hz, \(job.settings.bitrate)bit/s AAC.", type: .info)
        let modeName = job.settings.useParallelEncoding ? "Performance-Modus (Parallel)" : "Standard-Modus (Sequenziell)"
        let codecInfo = "Apple AudioToolbox / Constrained Variable Bitrate"
        session.addLog("Technik: \(modeName) via \(codecInfo)", type: .info)

        DispatchQueue.global(qos: .userInitiated).async {
            let heldOutputLeases = job.outputLeases
            defer { withExtendedLifetime(heldOutputLeases) {} }
            // Verfolgt, ob ALLE Gruppen erfolgreich waren -- nur dann ist der Lauf
            // wirklich erfolgreich (für CLI-Exit-Code + ehrliche Statusmeldung).
            var overallSuccess = true
            var completedDuration: TimeInterval = 0
            // Erfolgreich übernommene Ziel-URLs hier im Worker sammeln und erst
            // mit der EINEN Abschlussnachricht übergeben — separate Tasks pro
            // Datei hätten keine garantierte Reihenfolge gegenüber dem Abschluss.
            var committedOutputs: [URL] = []

            for (groupIndex, fileGroup) in job.plan.groups.enumerated() {
                if context.isCancelled {
                    overallSuccess = false
                    break
                }
                do {
                    try validateInputSnapshots(
                        for: fileGroup,
                        expected: job.plan.inputSnapshots
                    )
                } catch {
                    session.enqueueLog(
                        "❌ \(error.localizedDescription)",
                        type: .highlight,
                        runID: context.id
                    )
                    overallSuccess = false
                    break
                }
                let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("HB_Temp_\(UUID().uuidString)")
                do {
                    try createOwnedTempDirectory(tempDir)
                } catch {
                    session.enqueueLog(
                        "❌ Temporäres Arbeitsverzeichnis konnte nicht erstellt werden: \(error.localizedDescription)",
                        type: .highlight,
                        runID: context.id
                    )
                    overallSuccess = false
                    break
                }
                context.registerTempDirectory(tempDir)

                let finalURL = job.plan.outputURLs[groupIndex]
                do {
                    try validateOutputDirectorySnapshot(
                        for: finalURL,
                        expected: job.plan.outputDirectorySnapshots[groupIndex]
                    )
                } catch {
                    session.enqueueLog(
                        "❌ \(error.localizedDescription)",
                        type: .highlight,
                        runID: context.id
                    )
                    context.removeTempDirectory(tempDir)
                    overallSuccess = false
                    break
                }
                // Leichen abgestürzter früherer Läufe (SIGKILL/Stromausfall)
                // für dieses Ziel zuerst wegräumen — sie sind versteckt, oft
                // mehrere GB groß und sonst für immer unsichtbar.
                removeOrphanedStagedOutputs(for: finalURL, log: { message in
                    session.enqueueLog(message, type: .highlight, runID: context.id)
                })
                let stagingHandle: StagingOutputHandle
                do {
                    stagingHandle = try createProtectedStagingOutput(for: finalURL)
                } catch {
                    session.enqueueLog(
                        "❌ Temporäre Ausgabedatei konnte nicht exklusiv angelegt werden: \(error.localizedDescription)",
                        type: .highlight,
                        runID: context.id
                    )
                    context.removeTempDirectory(tempDir)
                    overallSuccess = false
                    break
                }
                let stagedURL = stagingHandle.url
                let stagingOwnership = stagingHandle.ownership
                context.registerStagedOutput(
                    stagedURL,
                    ownership: stagingOwnership
                )
                var success = false
                let groupDuration = fileGroup.reduce(0) { $0 + $1.duration }
                let progressBase = plannedTotalDuration > 0
                    ? completedDuration / plannedTotalDuration
                    : 0
                let progressScale = plannedTotalDuration > 0
                    ? groupDuration / plannedTotalDuration
                    : 1

                if job.settings.useParallelEncoding {
                    success = performParallelConversion(
                        session: session,
                        job: job,
                        context: context,
                        group: fileGroup,
                        tempDir: tempDir,
                        finalURL: stagedURL,
                        stagingOwnership: stagingOwnership,
                        stagingHandle: stagingHandle,
                        progressBase: progressBase,
                        progressScale: progressScale
                    )
                } else {
                    success = performSequentialConversion(
                        session: session,
                        job: job,
                        context: context,
                        group: fileGroup,
                        tempDir: tempDir,
                        finalURL: stagedURL,
                        stagingOwnership: stagingOwnership,
                        stagingHandle: stagingHandle,
                        progressBase: progressBase,
                        progressScale: progressScale
                    )
                }

                guard success, !context.isCancelled, let size = regularFileSize(stagedURL) else {
                    context.discardStagedOutput(stagedURL)
                    if !context.isCancelled {
                        session.enqueueLog(
                            "❌ KRITISCHER FEHLER beim Erstellen von \(finalURL.lastPathComponent). Vorgang abgebrochen.",
                            type: .highlight,
                            runID: context.id
                        )
                    }
                    context.removeTempDirectory(tempDir)
                    overallSuccess = false
                    break
                }

                // Die rein informative Analyse läuft auf der Staging-Datei. Der
                // atomare Rename bleibt damit der letzte relevante Dateischritt.
                if let miPath = getBinaryURL(name: "mediainfo"), !context.isCancelled {
                    let result = runCapturedProcess(
                        executableURL: miPath,
                        arguments: [stagedURL.path],
                        context: context,
                        timeout: 10
                    )
                    switch result {
                    case .completed(let status, let data) where status == 0:
                        if let output = String(data: data, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           !output.isEmpty, !context.isCancelled {
                            session.enqueueLog(
                                "--- MediaInfo Eigenschaften ---\n" + output,
                                type: .dim,
                                runID: context.id
                            )
                            // Gilt in BEIDEN Modi: aac_at/CVBR wird von ffmpeg+mediainfo
                            // immer als 'Constant' gelabelt (verifiziert), nicht nur beim
                            // Stream-Copy. Der Audio-Stream bleibt dennoch Constrained VBR.
                            session.enqueueLog(
                                "Hinweis: MediaInfo labelt aac_at/CVBR fälschlicherweise als 'Bitrate-Modus: Constant'. Die Audiodaten sind dennoch durchgehend variables Apple CVBR.",
                                type: .dim,
                                runID: context.id
                            )
                        }
                    case .cancelled:
                        break
                    case .timedOut:
                        session.enqueueVerboseLog(
                            "MediaInfo-Nachanalyse nach 10 Sekunden beendet; die fertige Ausgabe wird trotzdem übernommen.",
                            runID: context.id
                        )
                    case .completed(let status, _):
                        session.enqueueVerboseLog(
                            "MediaInfo-Nachanalyse mit Exit-Code \(status) übersprungen; die fertige Ausgabe wird trotzdem übernommen.",
                            runID: context.id
                        )
                    case .failed(let reason):
                        session.enqueueVerboseLog(
                            "MediaInfo-Nachanalyse übersprungen: \(reason)",
                            runID: context.id
                        )
                    }
                }

                do {
                    var displacedOutputRemoved = true
                    let committed = try context.performCommit(
                        isLastOutput: groupIndex == job.plan.groups.count - 1
                    ) {
                        displacedOutputRemoved = try commitStagedOutput(
                            stagedURL,
                            to: finalURL,
                            expectedDestination: job.plan.outputSnapshots[groupIndex],
                            expectedDestinationDirectory:
                                job.plan.outputDirectorySnapshots[groupIndex],
                            expectedStagingOwnership: stagingOwnership
                        )
                    }
                    guard committed else {
                        context.discardStagedOutput(stagedURL)
                        context.removeTempDirectory(tempDir)
                        overallSuccess = false
                        break
                    }
                    if displacedOutputRemoved {
                        // Der Staging-Eintrag ist verschoben oder die verdrängte
                        // Altdatei wurde bestätigt gelöscht.
                        context.completeStagedOutput(stagedURL)
                    } else {
                        if case .existing(let displacedIdentity) =
                            job.plan.outputSnapshots[groupIndex] {
                            context.registerDisplacedOutput(
                                stagedURL,
                                expectedIdentity: displacedIdentity,
                                stagingOwnership: stagingOwnership
                            )
                        }
                        session.enqueueLog(
                            "⚠️ Die frühere Ausgabe bleibt vorläufig als versteckte Sicherungsdatei liegen: \(stagedURL.path)",
                            type: .highlight,
                            runID: context.id
                        )
                    }
                    clearStagingOwnershipMarker(finalURL)
                    committedOutputs.append(finalURL)
                } catch {
                    context.handleCommitFailure(error, stagedURL: stagedURL)
                    session.enqueueLog(
                        "❌ Ausgabe konnte nicht atomar übernommen werden: \(error.localizedDescription)",
                        type: .highlight,
                        runID: context.id
                    )
                    context.removeTempDirectory(tempDir)
                    overallSuccess = false
                    break
                }

                session.enqueueLog("✅ Datei erfolgreich erstellt!", type: .highlight, runID: context.id)
                session.enqueueLog("Name: \(finalURL.lastPathComponent)", type: .info, runID: context.id)
                session.enqueueLog("Pfad: \(finalURL.path)", type: .info, runID: context.id)
                session.enqueueLog("Größe: \(formatFileSize(size))", type: .info, runID: context.id)
                context.removeTempDirectory(tempDir)
                completedDuration += groupDuration
            }

            let succeeded = overallSuccess
            let outputs = committedOutputs
            context.finishAfterCancellationCleanup { cancelled in
                // Erst nach einer parallel laufenden Abbruchbereinigung erneut
                // versuchen: Diese kann gerade erst einen Rest registriert haben.
                context.cleanupResidualStagedOutputs()
                session.enqueueConversionFinished(
                    success: succeeded,
                    cancelled: cancelled,
                    completedOutputs: outputs,
                    runID: context.id
                )
            }
        }
        return .started
    }

    private static func runParallelTasks(group: [AudioFile], tempDir: URL, session: ConversionSession, context: ConversionContext,
                                         progressBase: Double, progressWeight: Double,
                                         extensionStr: String, showIndividualPacmans: Bool,
                                         inputSnapshots: [String: OutputDestinationSnapshot],
                                         argsProvider: @escaping @Sendable (Int, AudioFile, URL) -> [String]) -> [String]? {
        // ffmpeg einmal vorab auflösen. Fehlt es, die Ursache klar benennen und
        // abbrechen — der frühere /usr/bin/false-Fallback pro Segment erzeugte
        // nur irreführende "Segment fehlgeschlagen"-Meldungen.
        guard let ffmpegURL = getBinaryURL(name: "ffmpeg") else {
            session.enqueueLog(
                "❌ ffmpeg wurde nicht gefunden (weder gebündelt noch im PATH/Homebrew/MacPorts). Bitte ./build.sh ausführen oder ffmpeg installieren.",
                type: .highlight,
                runID: context.id
            )
            return nil
        }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let maxConcurrent = max(1, cores - 1)
        let semaphore = DispatchSemaphore(value: maxConcurrent)
        let groupQueue = DispatchQueue(label: "com.hoerbuchkloppler.parallel", attributes: .concurrent)
        let completionGroup = DispatchGroup()
        
        let results = ParallelResults(count: group.count)
        let tracker = ParallelProgressTracker()
        let itemCount = group.count

        session.enqueueSegmentReset(
            title: showIndividualPacmans ? nil : "Audio-Dekodierung (WAV)",
            runID: context.id
        )

        for (idx, file) in group.enumerated() {
            completionGroup.enter()
            groupQueue.async {
                semaphore.wait()
                defer {
                    semaphore.signal()
                    completionGroup.leave()
                }

                if context.isCancelled {
                    return
                }
                do {
                    try validateInputSnapshots(for: [file], expected: inputSnapshots)
                } catch {
                    session.enqueueLog(
                        "❌ \(error.localizedDescription)",
                        type: .highlight,
                        runID: context.id
                    )
                    return
                }
                
                let segmentURL = tempDir.appendingPathComponent("seg_\(idx).\(extensionStr)")
                let finalArgs = argsProvider(idx, file, segmentURL)
                
                if showIndividualPacmans {
                    session.enqueueSegmentInitialization(
                        index: idx,
                        filename: file.name,
                        runID: context.id
                    )
                }

                let process = Process()
                process.executableURL = ffmpegURL
                process.arguments = finalArgs
                
                defer { context.unregister(process) }
                
                session.enqueueVerboseLog(
                    "Starte Segment \(idx+1): ffmpeg \(finalArgs.joined(separator: " "))",
                    runID: context.id
                )
                
                let errorPipe = Pipe()
                process.standardError = errorPipe
                let outputReader = ProcessPipeReader(
                    handle: errorPipe.fileHandleForReading
                )
                let progressParser = FFmpegProgressParser()

                let consumeProgress: @Sendable (Data) -> Void = { data in
                    if let currentSeconds = progressParser.consume(data),
                       file.duration > 0 {
                                let p = min(1, max(0, currentSeconds / file.duration))
                                let totalP = tracker.update(
                                    index: idx,
                                    progress: p,
                                    itemCount: itemCount
                                )
                                session.enqueueProgress(
                                    mappedProgress(
                                        base: progressBase,
                                        weight: progressWeight,
                                        phaseProgress: totalP
                                    ),
                                    segmentIndex: showIndividualPacmans ? idx : 0,
                                    segmentProgress: showIndividualPacmans ? p : totalP,
                                    runID: context.id
                                )
                    }
                }

                do {
                    guard try context.run(process) else { return }
                    try? errorPipe.fileHandleForWriting.close()
                    outputReader.start(onChunk: consumeProgress)
                    process.waitUntilExit()
                    let hadBackgroundProcesses = ProcessTerminator
                        .terminateRemainingOwnedGroup(process)
                    // Join des Lesers vor Status/Phasenwechsel: Kein Callback aus
                    // diesem Segment darf danach noch Fortschritt einreihen.
                    let stderrData = outputReader.waitUntilEOF(timeout: 0.25) {
                        ProcessTerminator.terminateAndWait([process])
                    }
                    if context.isCancelled { return }
                    if hadBackgroundProcesses {
                        session.enqueueLog(
                            "❌ Segment \(idx+1) ließ nach dem Werkzeug-Exit Hintergrundprozesse zurück; der Batch wird verworfen.",
                            type: .highlight,
                            runID: context.id
                        )
                        return
                    }
                    do {
                        // ffmpeg öffnet die URL selbst. Eine während des Lesens
                        // ersetzte oder in-place geänderte Quelle darf deshalb
                        // auch bei Exit 0 kein gültiges Segment liefern.
                        try validateInputSnapshots(
                            for: [file],
                            expected: inputSnapshots
                        )
                    } catch {
                        session.enqueueLog(
                            "❌ \(error.localizedDescription)",
                            type: .highlight,
                            runID: context.id
                        )
                        return
                    }
                    if process.terminationStatus == 0 {
                        var fileIsValid = false
                        if let attr = try? FileManager.default.attributesOfItem(atPath: segmentURL.path),
                           let size = attr[.size] as? Int64, size > 0 {
                            fileIsValid = true
                        }
                        
                        if fileIsValid {
                            let finishedCount = results.store(segmentURL.path, at: idx)
                            let totalProgress = tracker.update(
                                index: idx,
                                progress: 1,
                                itemCount: itemCount
                            )
                            session.enqueueProgress(
                                mappedProgress(
                                    base: progressBase,
                                    weight: progressWeight,
                                    phaseProgress: totalProgress
                                ),
                                segmentIndex: showIndividualPacmans || finishedCount == itemCount
                                    ? (showIndividualPacmans ? idx : 0)
                                    : nil,
                                segmentProgress: showIndividualPacmans || finishedCount == itemCount
                                    ? 1
                                    : nil,
                                runID: context.id
                            )
                        } else {
                            session.enqueueLog(
                                "❌ KRITISCHER FEHLER: Zieldatei Segment \(idx+1) ist leer oder fehlt.",
                                type: .highlight,
                                runID: context.id
                            )
                        }
                    } else {
                        let errorString = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let errorMessage = (errorString?.isEmpty == false) ? errorString! : "Unbekannter FFmpeg Fehler"
                        session.enqueueLog(
                            "❌ Segment \(idx+1) fehlgeschlagen (Exit-Code \(process.terminationStatus)):\n\(errorMessage)",
                            type: .highlight,
                            runID: context.id
                        )
                    }
                } catch {
                    if !context.isCancelled {
                        session.enqueueLog(
                            "❌ Prozess-Fehler bei Segment \(idx+1): \(error.localizedDescription)",
                            type: .highlight,
                            runID: context.id
                        )
                    }
                }
            }
        }
        completionGroup.wait()
        return results.completedPaths()
    }

    /// Schreibt die concat-Liste (`audio_list.txt`) und die FFMETADATA-
    /// Kapiteldatei (`chapters.txt`) nach tempDir. Gibt `false` zurück, wenn ein
    /// Schreibvorgang fehlschlägt — sonst liefe ffmpeg mit fehlender Steuerdatei
    /// weiter und meldete einen irreführenden Fehler. Pfade werden fürs
    /// concat-Format escaped (einfaches Anführungszeichen → `'\''`).
    /// Baut den FFMETADATA-Inhalt (`chapters.txt`) für eine Kapitelgruppe.
    /// Kapitel liegen hintereinander: jedes beginnt, wo das vorherige endet.
    ///
    /// Bewusst eine reine Funktion ohne Datei-I/O — so ist die Kapitel-Arithmetik
    /// (Grenzen, Escaping) testbar, ohne echte Dateien schreiben zu müssen.
    static func buildChapterMetadata(group: [AudioFile]) -> String {
        var metaContent = ";FFMETADATA1\n"
        var currentTime: TimeInterval = 0
        for file in group {
            metaContent += "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(Int(currentTime * 1000))\nEND=\(Int((currentTime + file.duration) * 1000))\ntitle=\(escapeFFMetadata(file.chapterTitle))\n"
            currentTime += file.duration
        }
        return metaContent
    }

    private static func writeConcatAndChapters(
        validPaths: [String],
        group: [AudioFile],
        listFile: URL,
        metaFile: URL,
        session: ConversionSession,
        runID: UUID
    ) -> Bool {
        let fileListContent = validPaths.map { "file '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
        let metaContent = buildChapterMetadata(group: group)
        do {
            try fileListContent.write(to: listFile, atomically: true, encoding: .utf8)
            try metaContent.write(to: metaFile, atomically: true, encoding: .utf8)
            return true
        } catch {
            session.enqueueLog(
                "❌ KRITISCHER FEHLER: Steuerdateien konnten nicht geschrieben werden: \(error.localizedDescription)",
                type: .highlight,
                runID: runID
            )
            return false
        }
    }

    /// Gemeinsamer MP4/M4B-Mux-Aufbau für Standard- und Parallelmodus. Nur die
    /// Audio-Codecargumente unterscheiden sich; Inputs, Metadaten, Cover-Mapping
    /// und Ausgabe müssen in beiden Pfaden identisch bleiben.
    private static func finalMuxArguments(
        listFile: URL,
        metaFile: URL,
        coverInput: String?,
        audioCodecArguments: [String],
        job: ConversionJob,
        finalURL: URL,
        outputPath: String? = nil
    ) -> [String] {
        var arguments = [
            "-nostdin", "-y", "-f", "concat", "-safe", "0", "-i", listFile.path,
            "-i", metaFile.path
        ]
        if let coverInput { arguments += ["-i", coverInput] }
        arguments += audioCodecArguments
        arguments += [
            "-map", "0:a", "-map_metadata", "1",
            "-metadata", "title=\(job.title)",
            "-metadata", "album=\(job.title)",
            "-metadata", "artist=\(job.author)",
            "-metadata", "genre=\(job.genre)"
        ]
        if coverInput != nil {
            arguments += ["-map", "2:0", "-c:v", "copy", "-disposition:v", "attached_pic"]
        }
        if let outputPath {
            // Der MP4-Muxer leitet das Format aus einem normalen Pfad ab. Beim
            // deskriptorgebundenen Produktionspfad braucht er es ausdrücklich.
            arguments += ["-f", "ipod", outputPath]
        } else {
            arguments.append(finalURL.path)
        }
        return arguments
    }

    /// Gemeinsamer Abschluss beider Kodiermodi: Steuerdateien und Cover
    /// vorbereiten, Mux-Argumente bauen und den finalen ffmpeg-Prozess starten.
    /// Der jeweilige Modus liefert nur seine Segmentpfade, Codec-Argumente und
    /// Fortschrittsaufteilung.
    private static func finalizeConvertedSegments(
        _ validPaths: [String],
        session: ConversionSession,
        job: ConversionJob,
        context: ConversionContext,
        group: [AudioFile],
        tempDir: URL,
        finalURL: URL,
        stagingOwnership: StagingOwnership,
        stagingHandle: StagingOutputHandle,
        progressBase: Double,
        progressScale: Double,
        segmentProgressFraction: Double,
        audioCodecArguments: [String],
        logMessage: String,
        pacmanTitle: String
    ) -> Bool {
        let listFile = tempDir.appendingPathComponent("audio_list.txt")
        let metaFile = tempDir.appendingPathComponent("chapters.txt")
        guard writeConcatAndChapters(
            validPaths: validPaths,
            group: group,
            listFile: listFile,
            metaFile: metaFile,
            session: session,
            runID: context.id
        ) else { return false }
        let coverInput = resolveCoverInputPath(
            job: job,
            session: session,
            tempDir: tempDir,
            runID: context.id
        )
        let args = finalMuxArguments(
            listFile: listFile,
            metaFile: metaFile,
            coverInput: coverInput,
            audioCodecArguments: audioCodecArguments,
            job: job,
            finalURL: finalURL,
            outputPath: "/dev/fd/0"
        )
        return runFinalProcess(
            args: args,
            session: session,
            context: context,
            progressBase: progressBase + progressScale * segmentProgressFraction,
            progressWeight: progressScale * (1 - segmentProgressFraction),
            phaseDuration: group.reduce(0) { $0 + $1.duration },
            logMessage: logMessage,
            pacmanTitle: pacmanTitle,
            stagingURL: finalURL,
            expectedStagingOwnership: stagingOwnership,
            stagingHandle: stagingHandle
        )
    }

    private static func performSequentialConversion(
        session: ConversionSession,
        job: ConversionJob,
        context: ConversionContext,
        group: [AudioFile],
        tempDir: URL,
        finalURL: URL,
        stagingOwnership: StagingOwnership,
        stagingHandle: StagingOutputHandle,
        progressBase: Double,
        progressScale: Double
    ) -> Bool {
        let wavPaths = runParallelTasks(group: group, tempDir: tempDir, session: session, context: context, progressBase: progressBase, progressWeight: progressScale * 0.2, extensionStr: "wav", showIndividualPacmans: false, inputSnapshots: job.plan.inputSnapshots) { _, file, url in
            FFmpegWrapper.getArgsForStandardSlicing(
                file: file,
                url: url,
                settings: job.settings
            )
        }
        guard let validPaths = wavPaths else { return false }
        return finalizeConvertedSegments(
            validPaths,
            session: session,
            job: job,
            context: context,
            group: group,
            tempDir: tempDir,
            finalURL: finalURL,
            stagingOwnership: stagingOwnership,
            stagingHandle: stagingHandle,
            progressBase: progressBase,
            progressScale: progressScale,
            segmentProgressFraction: 0.2,
            audioCodecArguments: [
                "-c:a", "aac_at", "-aac_at_mode", "cvbr",
                "-b:a", job.settings.bitrate,
                "-ar", "\(job.settings.sampleRate)",
                "-ac", job.settings.isMono ? "1" : "2"
            ],
            logMessage: "🛠️ Starte komplette Apple CVBR Kodierung...",
            pacmanTitle: "Apple AAC Encoding"
        )
    }

    private static func performParallelConversion(
        session: ConversionSession,
        job: ConversionJob,
        context: ConversionContext,
        group: [AudioFile],
        tempDir: URL,
        finalURL: URL,
        stagingOwnership: StagingOwnership,
        stagingHandle: StagingOutputHandle,
        progressBase: Double,
        progressScale: Double
    ) -> Bool {
        let aacPaths = runParallelTasks(group: group, tempDir: tempDir, session: session, context: context, progressBase: progressBase, progressWeight: progressScale * 0.9, extensionStr: "m4a", showIndividualPacmans: true, inputSnapshots: job.plan.inputSnapshots) { _, file, url in
            FFmpegWrapper.getArgsForParallelEncoding(
                file: file,
                url: url,
                settings: job.settings
            )
        }
        guard let validPaths = aacPaths else { return false }
        return finalizeConvertedSegments(
            validPaths,
            session: session,
            job: job,
            context: context,
            group: group,
            tempDir: tempDir,
            finalURL: finalURL,
            stagingOwnership: stagingOwnership,
            stagingHandle: stagingHandle,
            progressBase: progressBase,
            progressScale: progressScale,
            segmentProgressFraction: 0.9,
            audioCodecArguments: ["-c:a", "copy"],
            logMessage: "🛠️ Finaler Stream-Copy & MP4-Muxing gestartet...",
            pacmanTitle: "Finaler Zusammenbau"
        )
    }

    static func runFinalProcess(
        args: [String],
        session: ConversionSession,
        context: ConversionContext,
        progressBase: Double,
        progressWeight: Double,
        phaseDuration: TimeInterval,
        logMessage: String,
        pacmanTitle: String,
        stagingURL: URL? = nil,
        expectedStagingOwnership: StagingOwnership? = nil,
        stagingHandle: StagingOutputHandle? = nil,
        beforeProcessStart: (() -> Void)? = nil,
        executableURL: URL? = nil
    ) -> Bool {
        session.enqueueSegmentReset(title: pacmanTitle, runID: context.id)
        if context.isCancelled { return false }
        session.enqueueLog(logMessage, type: .highlight, runID: context.id)
        
        // Fehlendes ffmpeg klar melden statt (wie früher) /usr/bin/false zu starten,
        // dessen Exit-Code nur eine irreführende Fehlermeldung produzierte.
        guard let ffmpegURL = executableURL ?? getBinaryURL(name: "ffmpeg") else {
            session.enqueueLog(
                "❌ ffmpeg wurde nicht gefunden (weder gebündelt noch im PATH/Homebrew/MacPorts). Bitte ./build.sh ausführen oder ffmpeg installieren.",
                type: .highlight,
                runID: context.id
            )
            return false
        }
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = args
        if let stagingHandle {
            // Foundation erhält den offenen Staging-Deskriptor als stdin und
            // hält ihn beim Spawn als Dateideskriptor 0 offen. ffmpeg schreibt
            // nach /dev/fd/0 und folgt dadurch keinem austauschbaren Pfad.
            process.standardInput = stagingHandle.processInputHandle()
        }
        let pipe = Pipe()
        process.standardError = pipe
        session.enqueueVerboseLog(
            "Führe Final-Prozess aus: ffmpeg \(args.joined(separator: " "))",
            runID: context.id
        )
        
        defer { context.unregister(process) }
        
        do {
            if let stagingURL, let expectedStagingOwnership {
                guard case .existing(let current) = captureSnapshot(of: stagingURL),
                      stagingOwnershipMatches(
                        expectedStagingOwnership,
                        identity: current,
                        at: stagingURL
                      ),
                      let protectedDirectory = expectedStagingOwnership
                        .protectedDirectory,
                      let protectedIdentity = expectedStagingOwnership
                        .protectedDirectoryIdentity,
                      let currentDirectory = fileSystemIdentity(
                        at: protectedDirectory,
                        followSymlink: false
                      ),
                      protectedIdentity.matchesDirectoryEntry(currentDirectory),
                      temporaryDirectoryOwnerPID(protectedDirectory)
                        == expectedStagingOwnership.ownerPID else {
                    session.enqueueLog(
                        "❌ Geschützte temporäre Ausgabe wurde vor dem ffmpeg-Start ausgetauscht.",
                        type: .highlight,
                        runID: context.id
                    )
                    return false
                }
            }
            beforeProcessStart?()
            guard try context.run(process) else { return false }
            let outputReader = ProcessPipeReader(handle: pipe.fileHandleForReading)
            let progressParser = FFmpegProgressParser()
            try? pipe.fileHandleForWriting.close()
            outputReader.start { data in
                if let currentSeconds = progressParser.consume(data),
                   phaseDuration > 0 {
                            let p = min(1, max(0, currentSeconds / phaseDuration))
                            session.enqueueProgress(
                                mappedProgress(
                                    base: progressBase,
                                    weight: progressWeight,
                                    phaseProgress: p
                                ),
                                segmentIndex: 0,
                                segmentProgress: p,
                                runID: context.id
                            )
                }
            }
            
            process.waitUntilExit()
            let hadBackgroundProcesses = ProcessTerminator
                .terminateRemainingOwnedGroup(process)
            let stderrData = outputReader.waitUntilEOF(timeout: 0.25) {
                ProcessTerminator.terminateAndWait([process])
            }
            if context.isCancelled { return false }
            if hadBackgroundProcesses {
                session.enqueueLog(
                    "❌ KRITISCHER FEHLER: Werkzeug meldete Exit, ließ aber Hintergrundprozesse zurück. Die Ausgabe wird nicht übernommen.",
                    type: .highlight,
                    runID: context.id
                )
                return false
            }
            if process.terminationStatus == 0 {
                session.enqueueProgress(
                    mappedProgress(
                        base: progressBase,
                        weight: progressWeight,
                        phaseProgress: 1
                    ),
                    segmentIndex: 0,
                    segmentProgress: 1,
                    runID: context.id
                )
                return true
            }
            let details = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = details.map { $0.isEmpty ? "" : "\n\($0)" } ?? ""
            session.enqueueLog(
                "❌ KRITISCHER FEHLER beim finalen Zusammenfügen. "
                + "Exit-Code: \(process.terminationStatus)\(suffix)",
                type: .highlight,
                runID: context.id
            )
            return false
        } catch {
            if !context.isCancelled {
                session.enqueueLog(
                    "❌ KRITISCHER FEHLER: \(error.localizedDescription)",
                    type: .highlight,
                    runID: context.id
                )
            }
            return false
        }
    }

    /// Maskiert einen Wert fürs FFMETADATA-Format. `\`, `=`, `;` und `#` werden
    /// mit Backslash escaped; Zeilenumbrüche werden zu Leerzeichen (ein
    /// Kapiteltitel ist einzeilig). Ohne das zerstört z.B. ein Newline im
    /// Kapiteltitel die gesamte chapters.txt.
    ///
    /// Sonderfall Backslash am Zeilenende: ffmpegs FFMETADATA-Leser behandelt
    /// JEDEN Backslash am Zeilenende als Zeilenfortsetzung — auch den per `\\`
    /// maskierten — und würde die folgende `[CHAPTER]`-Zeile verschlucken (ein
    /// Kapitel ginge verloren). Ein FFMETADATA-Wert darf also nicht auf einen
    /// Backslash enden; abschließende Backslashes werden daher entfernt
    /// (ffmpeg kann sie ohnehin nicht verlustfrei zurücklesen).
    static func escapeFFMetadata(_ value: String) -> String {
        var out = ""
        for ch in value {
            switch ch {
            case "\\", "=", ";", "#": out.append("\\"); out.append(ch)
            case "\n", "\r": out.append(" ")
            default: out.append(ch)
            }
        }
        while out.hasSuffix("\\") { out.removeLast() }
        return out
    }

    /// Schreibt den vor Workerstart aufgenommenen Cover-Snapshot in `tempDir`
    /// und liefert seinen Pfad für ffmpeg. Damit liest der Mux weder eine später
    /// ausgetauschte manuelle Bilddatei noch veränderlichen Session-Zustand.
    private static func resolveCoverInputPath(
        job: ConversionJob,
        session: ConversionSession,
        tempDir: URL,
        runID: UUID
    ) -> String? {
        if let data = job.coverData {
            let coverURL = tempDir.appendingPathComponent("cover.img")
            do {
                try data.write(to: coverURL)
                return coverURL.path
            } catch {
                session.enqueueLog(
                    "⚠️ Eingebettetes Cover konnte nicht zwischengespeichert werden — Output ohne Cover.",
                    type: .info,
                    runID: runID
                )
                return nil
            }
        }
        return nil
    }

    static func resolveOutputURL(_ url: URL, groupIndex: Int, splitGroupsCount: Int) -> URL {
        if splitGroupsCount <= 1 { return url }
        let baseName = url.deletingPathExtension().lastPathComponent
        let fileExt = url.pathExtension
        let parentDir = url.deletingLastPathComponent()
        return parentDir.appendingPathComponent("\(baseName)-\(String(format: "%02d", groupIndex + 1))").appendingPathExtension(fileExt)
    }

    /// Versteckte Staging-Datei neben dem Ziel. Der Dateiname trägt die
    /// Besitzer-PID als überprüfbare Laufmarke: Nach SIGKILL/Absturz/Stromausfall
    /// kennt kein Kontext die Datei mehr, aber `removeOrphanedStagedOutputs`
    /// erkennt am toten Besitzer, dass die oft gigabytegroße Leiche weg darf.
    static func stagingOutputURL(
        for finalURL: URL,
        id: UUID = UUID(),
        ownerPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> URL {
        return hiddenSiblingURL(
            for: finalURL,
            marker: "partial-\(ownerPID)-\(id.uuidString)"
        )
    }

    /// Legt den späteren ffmpeg-Output exklusiv an und markiert genau diesen
    /// Inode per Extended Attribute. ffmpeg öffnet ihn mit `-y`/`O_TRUNC`; der
    /// Marker bleibt dabei erhalten. Ein untergeschobener Ersatz trägt ihn nicht
    /// und wird weder beim Abbruch noch durch die Altlastenbereinigung gelöscht.
    @discardableResult
    static func createOwnedStagingOutput(
        _ url: URL,
        ownerPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        setOwnershipMarker: (Int32, String) -> Int32 = setStagingOwnershipMarker
    ) throws -> StagingOwnership {
        let creation = try createOwnedStagingOutputAndDescriptor(
            url,
            ownerPID: ownerPID,
            setOwnershipMarker: setOwnershipMarker
        )
        _ = Darwin.close(creation.descriptor)
        return creation.ownership
    }

    private static func setStagingOwnershipMarker(
        _ descriptor: Int32,
        _ owner: String
    ) -> Int32 {
        owner.withCString { value in
            stagingOwnerAttribute.withCString { name in
                Darwin.fsetxattr(
                    descriptor,
                    name,
                    value,
                    strlen(value),
                    0,
                    XATTR_CREATE
                )
            }
        }
    }

    private static func createOwnedStagingOutputAndDescriptor(
        _ url: URL,
        ownerPID: pid_t,
        setOwnershipMarker: (Int32, String) -> Int32
    ) throws -> (ownership: StagingOwnership, descriptor: Int32) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return Darwin.open(
                path,
                O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o644)
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var createdInformation = stat()
        guard Darwin.fstat(descriptor, &createdInformation) == 0 else {
            let number = errno
            _ = Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: number) ?? .EIO)
        }
        let createdIdentity = FileSystemIdentity(stat: createdInformation)
        guard Darwin.fchmod(descriptor, mode_t(0o644)) == 0 else {
            let number = errno
            _ = Darwin.close(descriptor)
            _ = quarantineAndRemoveRegularFile(
                url,
                expectedIdentity: createdIdentity,
                cleanupPrefix: ".HB_StagingCleanup_",
                ownerPID: ownerPID,
                log: { _ in },
                stableIdentityOnly: true
            )
            throw POSIXError(POSIXErrorCode(rawValue: number) ?? .EIO)
        }
        let markerResult = setOwnershipMarker(descriptor, String(ownerPID))
        let markerError = errno
        var information = stat()
        let identityResult = Darwin.fstat(descriptor, &information)
        let identityError = errno
        let markerUnsupported = markerResult != 0
            && (markerError == ENOTSUP || markerError == EOPNOTSUPP)
        guard markerResult == 0 || markerUnsupported,
              identityResult == 0 else {
            _ = Darwin.close(descriptor)
            _ = quarantineAndRemoveRegularFile(
                url,
                expectedIdentity: createdIdentity,
                cleanupPrefix: ".HB_StagingCleanup_",
                ownerPID: ownerPID,
                log: { _ in },
                stableIdentityOnly: true
            )
            let number = identityResult == 0 ? markerError : identityError
            throw POSIXError(POSIXErrorCode(rawValue: number) ?? .EIO)
        }
        return (
            StagingOwnership(
                identity: FileSystemIdentity(stat: information),
                ownerPID: ownerPID,
                hasPersistentMarker: markerResult == 0,
                protectedDirectory: nil,
                protectedDirectoryIdentity: nil
            ),
            descriptor
        )
    }

    static func currentStagingOwnership(at url: URL) -> StagingOwnership? {
        guard let identity = fileSystemIdentity(at: url, followSymlink: false)
        else { return nil }
        let owner = stagedOutputOwnerPID(url)
            ?? ProcessInfo.processInfo.processIdentifier
        return StagingOwnership(
            identity: identity,
            ownerPID: owner,
            hasPersistentMarker: stagedOutputHasOwnershipMarker(
                url,
                expectedOwnerPID: owner
            ),
            protectedDirectory: nil,
            protectedDirectoryIdentity: nil
        )
    }

    /// Produktions-Staging liegt in einem exklusiv angelegten 0700-Ordner
    /// neben dem Ziel. ffmpeg erhält nur den Pfad innerhalb dieses Ordners;
    /// ein anderer Lauf oder ein Dateisynchronisierer kann den Ausgabepfad
    /// dadurch nicht am frei zugänglichen Zielordner austauschen.
    static func createProtectedStagingOutput(
        for finalURL: URL,
        ownerPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) throws -> StagingOutputHandle {
        let directory = finalURL.deletingLastPathComponent().appendingPathComponent(
            ".HB_StagingWork_\(ownerPID)-\(UUID().uuidString)"
        )
        try createOwnedTempDirectory(directory, ownerPID: ownerPID)
        guard let directoryIdentity = fileSystemIdentity(
            at: directory,
            followSymlink: false
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = directory.appendingPathComponent("entry.m4b")
        var expectedEntry: CleanupEntryRecord?
        var retainedDescriptor: Int32?
        do {
            let created = try createOwnedStagingOutputAndDescriptor(
                url,
                ownerPID: ownerPID,
                setOwnershipMarker: setStagingOwnershipMarker
            )
            retainedDescriptor = created.descriptor
            let ownership = StagingOwnership(
                identity: created.ownership.identity,
                ownerPID: ownerPID,
                hasPersistentMarker: created.ownership.hasPersistentMarker,
                protectedDirectory: directory,
                protectedDirectoryIdentity: directoryIdentity
            )
            expectedEntry = ownership.cleanupEntryRecord
            try writeCleanupEntryIdentity(
                ownership.identity,
                in: directory,
                filename: url.lastPathComponent,
                stableIdentityOnly: true
            )
            return StagingOutputHandle(
                url: url,
                ownership: ownership,
                descriptor: created.descriptor
            )
        } catch {
            if let retainedDescriptor {
                _ = Darwin.close(retainedDescriptor)
            }
            removeOwnedTempDirectory(
                directory,
                expectedIdentity: directoryIdentity,
                expectedOwnerPID: ownerPID,
                expectedCleanupEntry: expectedEntry
            )
            throw error
        }
    }

    static func stagedOutputHasOwnershipMarker(
        _ url: URL,
        expectedOwnerPID: pid_t
    ) -> Bool {
        var bytes = [CChar](repeating: 0, count: 32)
        let count = url.withUnsafeFileSystemRepresentation { path -> Int in
            guard let path else { return -1 }
            return stagingOwnerAttribute.withCString { name in
                Darwin.getxattr(
                    path,
                    name,
                    &bytes,
                    bytes.count - 1,
                    0,
                    XATTR_NOFOLLOW
                )
            }
        }
        guard count > 0, count < bytes.count else { return false }
        return String(decoding: bytes.prefix(count).map(UInt8.init), as: UTF8.self)
            == String(expectedOwnerPID)
    }

    static func clearStagingOwnershipMarker(_ url: URL) {
        _ = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return stagingOwnerAttribute.withCString { name in
                Darwin.removexattr(path, name, XATTR_NOFOLLOW)
            }
        }
    }

    private static func stagingOwnershipMatches(
        _ ownership: StagingOwnership?,
        identity: FileSystemIdentity,
        at url: URL
    ) -> Bool {
        guard let ownership else { return true }
        return ownership.identity.matchesRegularFileEntry(identity)
            && (!ownership.hasPersistentMarker
                || stagedOutputHasOwnershipMarker(
                    url,
                    expectedOwnerPID: ownership.ownerPID
                ))
    }

    /// Entfernt eine eigene Partial-Datei über einen zufälligen
    /// Quarantänenamen. Nach dem atomaren Rename wird der am Inode haftende
    /// Besitzer-Marker erneut geprüft; ein ausgetauschter Eintrag wird
    /// zurückgestellt und bleibt unangetastet.
    @discardableResult
    static func removeOwnedStagedOutput(
        _ url: URL,
        expectedOwnership: StagingOwnership? = nil,
        log: @Sendable (String) -> Void = { _ in },
        afterQuarantine: ((URL) -> Void)? = nil,
        beforeRestore: (() -> Void)? = nil
    ) -> Bool {
        if captureSnapshot(of: url) == .missing { return true }
        let owner: pid_t
        let persistentMarker: Bool
        let createdIdentity: FileSystemIdentity?
        if let expectedOwnership {
            owner = expectedOwnership.ownerPID
            persistentMarker = expectedOwnership.hasPersistentMarker
            createdIdentity = expectedOwnership.identity
        } else if let parsedOwner = stagedOutputOwnerPID(url) {
            owner = parsedOwner
            persistentMarker = true
            createdIdentity = nil
        } else {
            log("⚠️ Staging-Eintrag hat keine gültige Besitzer-Markierung und bleibt liegen: \(url.path)")
            return false
        }
        guard case .existing(let current) = captureSnapshot(of: url),
              current.mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              createdIdentity?.matchesRegularFileEntry(current) ?? true,
              !persistentMarker || stagedOutputHasOwnershipMarker(
                url,
                expectedOwnerPID: owner
              ) else {
            log("⚠️ Staging-Eintrag hat keine gültige Besitzer-Markierung oder gehört nicht mehr zu diesem Lauf und bleibt liegen: \(url.path)")
            return false
        }
        return quarantineAndRemoveRegularFile(
            url,
            expectedIdentity: current,
            cleanupPrefix: ".HB_StagingCleanup_",
            ownerPID: owner,
            log: log,
            afterQuarantine: afterQuarantine,
            beforeRestore: beforeRestore
        )
    }

    @discardableResult
    static func removeProtectedStagingOutput(
        _ url: URL,
        ownership: StagingOwnership,
        log: @Sendable (String) -> Void = { _ in }
    ) -> Bool {
        guard let directory = ownership.protectedDirectory,
              let directoryIdentity = ownership.protectedDirectoryIdentity else {
            return removeOwnedStagedOutput(
                url,
                expectedOwnership: ownership,
                log: log
            )
        }
        if captureSnapshot(of: directory) == .missing { return true }
        if captureSnapshot(of: url) == .missing {
            return removeProtectedStagingDirectoryBound(
                directory,
                identity: directoryIdentity,
                ownership: ownership
            )
        }
        guard let current = fileSystemIdentity(at: url, followSymlink: false),
              ownership.identity.matchesRegularFileEntry(current),
              !ownership.hasPersistentMarker || stagedOutputHasOwnershipMarker(
                url,
                expectedOwnerPID: ownership.ownerPID
              ) else {
            log("⚠️ Geschütztes Staging wurde ausgetauscht und bleibt als Recovery-Rest liegen: \(directory.path)")
            return false
        }
        return removeProtectedStagingDirectoryBound(
            directory,
            identity: directoryIdentity,
            ownership: ownership
        )
    }

    @discardableResult
    static func removeEmptyProtectedStagingDirectory(
        ownership: StagingOwnership
    ) -> Bool {
        guard let directory = ownership.protectedDirectory,
              let directoryIdentity = ownership.protectedDirectoryIdentity else {
            return true
        }
        return removeProtectedStagingDirectoryBound(
            directory,
            identity: directoryIdentity,
            ownership: ownership
        )
    }

    /// Der aktive Lauf löscht seinen geschützten Arbeitsordner direkt über
    /// einen geöffneten Verzeichnis-Deskriptor. Bei einem vorübergehenden
    /// Fehler bleibt derselbe Pfad registriert und kann am Laufende erneut
    /// versucht werden; eine zusätzliche Recovery-Datei bleibt unangetastet.
    @discardableResult
    private static func removeProtectedStagingDirectoryBound(
        _ directory: URL,
        identity: FileSystemIdentity,
        ownership: StagingOwnership
    ) -> Bool {
        if captureSnapshot(of: directory) == .missing { return true }
        guard let current = fileSystemIdentity(
            at: directory,
            followSymlink: false
        ),
        identity.matchesDirectoryEntry(current),
        temporaryDirectoryOwnerPID(directory) == ownership.ownerPID else {
            return false
        }
        let descriptor = openOwnedDirectory(directory)
        guard descriptor >= 0 else { return false }
        var boundInformation = stat()
        let boundMatches = Darwin.fstat(descriptor, &boundInformation) == 0
            && identity.matchesDirectoryEntry(
                FileSystemIdentity(stat: boundInformation)
            )
            && temporaryDirectoryOwnerPID(descriptor: descriptor)
                == ownership.ownerPID
        guard boundMatches else {
            _ = Darwin.close(descriptor)
            return false
        }
        let emptied = removeRecordedCleanupContentsBound(
            descriptor: descriptor,
            record: ownership.cleanupEntryRecord
        )
        _ = Darwin.close(descriptor)
        guard emptied,
              let stillVisible = fileSystemIdentity(
                at: directory,
                followSymlink: false
              ),
              identity.matchesDirectoryEntry(stillVisible) else {
            return false
        }
        let removed = removeEmptyDirectory(directory)
        return removed == 0 || errno == ENOENT
    }

    /// Gemeinsame Ableitung aller versteckten Nachbarnamen neben einem Ziel:
    /// führender Punkt, der auf `NAME_MAX` gekürzte Basisname, der jeweilige
    /// Marker und die Endung des Ziels. Staging- und Recovery-Namen dürfen sich
    /// nur im Marker unterscheiden — sonst greifen die Sweeps daneben, die
    /// genau an diesem Aufbau erkennen, was ihnen gehört.
    private static func hiddenSiblingURL(for finalURL: URL, marker: String) -> URL {
        let parent = finalURL.deletingLastPathComponent()
        let ext = finalURL.pathExtension.isEmpty ? "m4b" : finalURL.pathExtension
        return parent
            .appendingPathComponent(".\(stagingBasename(for: finalURL)).\(marker)")
            .appendingPathExtension(ext)
    }

    /// Recovery-Namen liegen bewusst außerhalb des `.partial-<PID>-`-Schemas:
    /// Die Altlastenbereinigung darf einen nach Rollback-Fehler geretteten
    /// fremden Eintrag auch nach einem Neustart niemals automatisch entfernen.
    static func recoveryOutputURL(for finalURL: URL, id: UUID = UUID()) -> URL {
        return hiddenSiblingURL(for: finalURL, marker: "recovery-\(id.uuidString)")
    }

    private static func preserveRecoveryEntry(
        from sourceURL: URL,
        for finalURL: URL,
        renameOperation: (URL, URL, UInt32) -> Int32
    ) -> URL? {
        for _ in 0..<4 {
            let recoveryURL = recoveryOutputURL(for: finalURL)
            if renameOperation(sourceURL, recoveryURL, UInt32(RENAME_EXCL)) == 0 {
                return recoveryURL
            }
            if errno != EEXIST { return nil }
        }
        return nil
    }

    /// Reserviert im Dateinamen Platz für Punkt, Marker, maximale PID, UUID und
    /// Endung. Die Kürzung arbeitet in UTF-8-Bytes, weil `NAME_MAX` Bytes und
    /// nicht Swift-Zeichen begrenzt.
    private static func stagingBasename(for finalURL: URL) -> String {
        let original = finalURL.deletingPathExtension().lastPathComponent
        let ext = finalURL.pathExtension.isEmpty ? "m4b" : finalURL.pathExtension
        let longestSuffix = ".partial-\(Int32.max)-00000000-0000-0000-0000-000000000000"
        let reservedBytes = 1 + longestSuffix.utf8.count + 1 + ext.utf8.count
        let limit = max(1, Int(NAME_MAX) - reservedBytes)
        var result = ""
        var byteCount = 0
        for character in original {
            let characterBytes = String(character).utf8.count
            if byteCount + characterBytes > limit { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result.isEmpty ? "output" : result
    }

    /// Liest die Besitzer-PID aus einem Staging-Dateinamen
    /// (`.<basename>.partial-<pid>-<uuid>.<ext>`). Liefert `nil` für das alte
    /// Format ohne PID und für alles, was keiner Staging-Datei ähnelt.
    static func stagedOutputOwnerPID(_ url: URL) -> pid_t? {
        let stem = url.deletingPathExtension().lastPathComponent
        // Von hinten suchen: Der Zieltitel selbst darf `.partial-` enthalten
        // (z.B. `Mein.partial-Buch.m4b` ergibt `.Mein.partial-Buch.partial-<pid>-<uuid>`).
        // Nur der letzte Marker ist der von uns angehängte; eine UUID enthält nie
        // `.partial-`, der Marker steht also garantiert am richtigen Platz.
        guard let range = stem.range(of: ".partial-", options: .backwards) else { return nil }
        let suffix = stem[range.upperBound...]
        guard let dash = suffix.firstIndex(of: "-"),
              let pid = pid_t(suffix[..<dash]),
              pid > 0,
              // Der Rest muss eine vollständige UUID sein. Das schließt das alte
              // Format `.partial-<uuid>` aus, dessen erste Zifferngruppe sonst
              // als PID durchginge.
              UUID(uuidString: String(suffix[suffix.index(after: dash)...])) != nil else {
            return nil
        }
        return pid
    }

    /// Entfernt verwaiste Staging-Dateien früherer Läufe für genau dieses Ziel.
    /// Verwaist = die im Namen vermerkte Besitzer-PID lebt nicht mehr. Dateien
    /// eines lebenden Prozesses (paralleler Lauf auf dasselbe Ziel) und Namen
    /// ohne PID-Marke bleiben unangetastet.
    static func removeOrphanedStagedOutputs(
        for finalURL: URL,
        caseSensitiveNames: Bool? = nil,
        log: @Sendable (String) -> Void = { _ in },
        beforeUnlink: ((URL) -> Void)? = nil
    ) {
        let fileManager = FileManager.default
        let parent = finalURL.deletingLastPathComponent()
        cleanupOutputQuarantines(in: parent, log: log)
        let basename = stagingBasename(for: finalURL)
        let prefix = ".\(basename).partial-"
        let expectedExtension = finalURL.pathExtension.isEmpty
            ? "m4b" : finalURL.pathExtension
        // Basisname und Endung müssen NACH DERSELBEN Regel verglichen werden,
        // und zwar nach der des Volumes: Auf einem case-insensitiven Volume
        // (macOS-Standard) sind `Buch.M4B` und `Buch.m4b` dasselbe Ziel, auf
        // einem case-sensitiven zwei verschiedene. Vorher wurde die Endung
        // immer kleingeschrieben verglichen, der Basisname aber immer exakt —
        // beides ging je nach Volume daneben (Review-Fund 2026-08-17).
        // Liefert das Volume die Eigenschaft nicht (bei Netz-/FUSE-Mounts
        // möglich), gilt das macOS-Standardverhalten: case-insensitiv.
        let caseSensitive = caseSensitiveNames
            ?? (try? parent.resourceValues(
                forKeys: [.volumeSupportsCaseSensitiveNamesKey]
            ))?.volumeSupportsCaseSensitiveNames
            ?? false
        func sameName(_ candidate: String, _ expected: String) -> Bool {
            caseSensitive ? candidate == expected
                : candidate.compare(expected, options: .caseInsensitive) == .orderedSame
        }
        func startsWithPrefix(_ candidate: String) -> Bool {
            caseSensitive ? candidate.hasPrefix(prefix)
                : candidate.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
        }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for url in contents where startsWithPrefix(url.lastPathComponent)
            && sameName(url.pathExtension, expectedExtension) {
            guard let owner = stagedOutputOwnerPID(url) else { continue }
            // Gleiche Lebend-Prüfung wie bei den Temp-Verzeichnissen: EPERM
            // heißt "existiert, gehört jemand anderem" — also nicht anfassen.
            if Darwin.kill(owner, 0) == 0 || errno == EPERM { continue }
            // Nur ein vom Erzeuger exklusiv angelegter und am Inode markierter
            // Eintrag ist unsere Altlast. Ein fremder Ersatz oder eine nach
            // fehlgeschlagenem Rollback verdrängte Zieldatei bleibt erhalten.
            guard stagedOutputHasOwnershipMarker(
                url,
                expectedOwnerPID: owner
            ) else {
                log("⚠️ Unmarkierter Staging-Eintrag bleibt liegen: \(url.path)")
                continue
            }
            // `contentsOfDirectory` liefert auch Ordner. Nie rekursiv löschen;
            // den liegengebliebenen Eintrag aber sichtbar melden.
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true else {
                log("⚠️ Staging-Eintrag ist keine reguläre Datei und bleibt liegen: \(url.path)")
                continue
            }
            // Der Hook macht im Test den Typwechsel nach der Prüfung
            // deterministisch. `unlink` entfernt genau diesen Verzeichniseintrag
            // und verweigert einen inzwischen eingesetzten Ordner atomar; anders
            // als `removeItem` kann es dessen Inhalt nicht rekursiv löschen.
            beforeUnlink?(url)
            ConversionContext.unlinkStagedOutput(url, log: log)
        }
    }

    /// Entfernt nach einem Prozessabsturz zurückgebliebene, exklusiv
    /// angelegte Cleanup-Verzeichnisse neben einem Ausgabeziel. Der exakte Name,
    /// die Besitzerdatei und ESRCH müssen gemeinsam einen toten Lauf belegen.
    static func cleanupOutputQuarantines(
        in parent: URL,
        log: @Sendable (String) -> Void = { _ in }
    ) {
        let prefixes = [
            ".HB_StagingWork_",
            ".HB_StagingCleanup_",
            ".HB_DisplacedCleanup_",
            ".HB_Cleanup_"
        ]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents {
            guard let prefix = prefixes.first(where: {
                url.lastPathComponent.hasPrefix($0)
            }) else { continue }
            let suffix = url.lastPathComponent.dropFirst(prefix.count)
            let parts = suffix.split(separator: "-", maxSplits: 1)
            guard parts.count == 2,
                  let owner = pid_t(parts[0]),
                  owner > 0,
                  UUID(uuidString: String(parts[1])) != nil,
                  let identity = fileSystemIdentity(at: url, followSymlink: false),
                  identity.mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  temporaryDirectoryOwnerPID(url) == owner else { continue }
            guard Darwin.kill(owner, 0) != 0, errno == ESRCH else { continue }
            guard let entryRecord = cleanupEntryRecord(in: url),
                  cleanupEntryMatchesRecordedIdentity(
                    entryRecord,
                    in: url
                  ) else {
                log("⚠️ Cleanup-Rest enthält keinen eindeutig eigenen Eintrag und bleibt liegen: \(url.path)")
                continue
            }
            removeOwnedTempDirectory(
                url,
                expectedIdentity: identity,
                expectedOwnerPID: owner,
                expectedCleanupEntry: entryRecord
            )
            if captureSnapshot(of: url) != .missing {
                log("⚠️ Verwaister Cleanup-Rest konnte nicht entfernt werden: \(url.path)")
            }
        }
    }

    static func writeCleanupEntryIdentity(
        _ identity: FileSystemIdentity,
        in cleanupDirectory: URL,
        filename: String = "entry",
        stableIdentityOnly: Bool = false,
        alternateIdentity: FileSystemIdentity? = nil,
        alternateStableIdentityOnly: Bool? = nil
    ) throws {
        let data = try JSONEncoder().encode(CleanupEntryRecord(
            identity: identity,
            filename: filename,
            stableIdentityOnly: stableIdentityOnly,
            alternateIdentity: alternateIdentity,
            alternateStableIdentityOnly: alternateStableIdentityOnly
        ))
        try data.write(
            to: cleanupDirectory.appendingPathComponent(
                cleanupEntryIdentityFilename
            ),
            options: .atomic
        )
    }

    private static func cleanupEntryRecord(
        in cleanupDirectory: URL
    ) -> CleanupEntryRecord? {
        let marker = cleanupDirectory.appendingPathComponent(
            cleanupEntryIdentityFilename
        )
        guard let data = try? Data(contentsOf: marker),
              let record = try? JSONDecoder().decode(
                CleanupEntryRecord.self,
                from: data
              ) else { return nil }
        return record
    }

    private static func cleanupEntryMatchesRecordedIdentity(
        _ record: CleanupEntryRecord,
        in cleanupDirectory: URL
    ) -> Bool {
        let entry = cleanupDirectory.appendingPathComponent(record.filename)
        switch captureSnapshot(of: entry) {
        case .missing:
            return true
        case .existing(let current):
            return record.matches(current)
        case .inaccessible:
            return false
        }
    }

    /// Quarantänisiert eine beim Swap verdrängte, vollständig identifizierte
    /// Altdatei. Ein Austausch vor dem Rename bleibt am Ursprung; ein Austausch
    /// danach fällt bei der erneuten Identitätsprüfung auf und wird zurückgestellt.
    @discardableResult
    static func removeDisplacedOutput(
        _ url: URL,
        expectedIdentity: FileSystemIdentity,
        cleanupParent: URL? = nil,
        log: @Sendable (String) -> Void = { _ in },
        beforeQuarantine: (() -> Void)? = nil,
        afterQuarantine: ((URL) -> Void)? = nil,
        beforeRestore: (() -> Void)? = nil
    ) -> Bool {
        guard case .existing(let current) = captureSnapshot(of: url),
              expectedIdentity.matchesDisplacedEntry(current) else {
            if captureSnapshot(of: url) == .missing { return true }
            log("⚠️ Verdrängte Ausgabe wurde ausgetauscht und bleibt liegen: \(url.path)")
            return false
        }
        return quarantineAndRemoveRegularFile(
            url,
            expectedIdentity: expectedIdentity,
            cleanupPrefix: ".HB_DisplacedCleanup_",
            ownerPID: ProcessInfo.processInfo.processIdentifier,
            cleanupParent: cleanupParent,
            log: log,
            beforeQuarantine: beforeQuarantine,
            afterQuarantine: afterQuarantine,
            beforeRestore: beforeRestore
        )
    }

    /// Verschiebt eine geprüfte Einzeldatei in ein exklusiv angelegtes
    /// 0700-Cleanup-Verzeichnis. Die anschließende rekursive Entfernung ist an
    /// dessen offenen Deskriptor gebunden; ein Austausch des sichtbaren
    /// Quarantänepfads kann daher keine fremde Datei außerhalb dieses eigens
    /// angelegten Bereichs treffen. Ein absichtlicher Prozess derselben
    /// Unix-Benutzer-ID bleibt außerhalb dieser Schutzgrenze, weil `unlinkat`
    /// keinen erwarteten Inode als atomare Bedingung annimmt; Details stehen in
    /// `docs/operations.md`.
    @discardableResult
    private static func quarantineAndRemoveRegularFile(
        _ url: URL,
        expectedIdentity: FileSystemIdentity,
        cleanupPrefix: String,
        ownerPID: pid_t,
        cleanupParent: URL? = nil,
        log: @Sendable (String) -> Void,
        beforeQuarantine: (() -> Void)? = nil,
        afterQuarantine: ((URL) -> Void)? = nil,
        beforeRestore: (() -> Void)? = nil,
        stableIdentityOnly: Bool = false
    ) -> Bool {
        let sourceParent = url.deletingLastPathComponent()
        let cleanupDirectory = (cleanupParent ?? sourceParent).appendingPathComponent(
            "\(cleanupPrefix)\(ownerPID)-\(UUID().uuidString)"
        )
        do {
            try createOwnedTempDirectory(cleanupDirectory, ownerPID: ownerPID)
        } catch {
            log("⚠️ Cleanup-Verzeichnis konnte nicht angelegt werden: \(cleanupDirectory.path) (\(error.localizedDescription))")
            return false
        }
        guard let cleanupIdentity = fileSystemIdentity(
            at: cleanupDirectory,
            followSymlink: false
        ) else { return false }
        let entryRecord = CleanupEntryRecord(
            identity: expectedIdentity,
            filename: "entry",
            stableIdentityOnly: stableIdentityOnly
        )
        do {
            try writeCleanupEntryIdentity(
                expectedIdentity,
                in: cleanupDirectory,
                stableIdentityOnly: stableIdentityOnly
            )
        } catch {
            removeOwnedTempDirectory(
                cleanupDirectory,
                expectedIdentity: cleanupIdentity,
                expectedOwnerPID: ownerPID,
                expectedCleanupEntry: entryRecord
            )
            log("⚠️ Cleanup-Identität konnte nicht gesichert werden: \(cleanupDirectory.path) (\(error.localizedDescription))")
            return false
        }
        let quarantined = cleanupDirectory.appendingPathComponent("entry")
        beforeQuarantine?()
        guard renameEntry(
            from: url,
            to: quarantined,
            flags: UInt32(RENAME_EXCL)
        ) == 0 else {
            let number = errno
            removeOwnedTempDirectory(
                cleanupDirectory,
                expectedIdentity: cleanupIdentity,
                expectedOwnerPID: ownerPID
            )
            if number == ENOENT { return true }
            log("⚠️ Datei konnte nicht quarantänisiert werden: \(url.path) (\(String(cString: strerror(number))))")
            return false
        }
        let movedMatches: Bool
        if case .existing(let moved) = captureSnapshot(of: quarantined) {
            movedMatches = stableIdentityOnly
                ? expectedIdentity.matchesRegularFileEntry(moved)
                : expectedIdentity.matchesDisplacedEntry(moved)
        } else {
            movedMatches = false
        }
        guard movedMatches else {
            beforeRestore?()
            let restored = renameEntry(
                from: quarantined,
                to: url,
                flags: UInt32(RENAME_EXCL)
            ) == 0
            if restored {
                removeOwnedTempDirectory(
                    cleanupDirectory,
                    expectedIdentity: cleanupIdentity,
                    expectedOwnerPID: ownerPID,
                    expectedCleanupEntry: entryRecord
                )
                log("⚠️ Ausgetauschte Datei bleibt liegen: \(url.path)")
                return false
            }
            if let recoveryURL = preserveRecoveryEntry(
                from: quarantined,
                for: url,
                renameOperation: {
                    renameEntry(from: $0, to: $1, flags: $2)
                }
            ) {
                removeOwnedTempDirectory(
                    cleanupDirectory,
                    expectedIdentity: cleanupIdentity,
                    expectedOwnerPID: ownerPID,
                    expectedCleanupEntry: entryRecord
                )
                log("⚠️ Ausgetauschte Datei wurde unter einem Recovery-Namen gesichert: \(recoveryURL.path)")
                return false
            }
            let recoveryDirectory = sourceParent.appendingPathComponent(
                ".HB_RecoveryCleanup_\(UUID().uuidString)"
            )
            let recoveryDirectoryCreated = renameEntry(
                from: cleanupDirectory,
                to: recoveryDirectory,
                flags: UInt32(RENAME_EXCL)
            ) == 0
            if !recoveryDirectoryCreated {
                // Ohne gültige Besitzerdatei nimmt kein automatischer Sweep
                // diesen nicht eindeutig eigenen Eintrag mehr auf.
                let descriptor = openOwnedDirectory(cleanupDirectory)
                if descriptor >= 0 {
                    var information = stat()
                    if Darwin.fstat(descriptor, &information) == 0,
                       cleanupIdentity.matchesDirectoryEntry(
                        FileSystemIdentity(stat: information)
                       ) {
                        _ = tempOwnerFilename.withCString {
                            Darwin.unlinkat(descriptor, $0, 0)
                        }
                    }
                    _ = Darwin.close(descriptor)
                }
            }
            let remainingPath = recoveryDirectoryCreated
                ? recoveryDirectory.path : cleanupDirectory.path
            log("⚠️ Ausgetauschte Datei bleibt in einem Recovery-Cleanup-Verzeichnis erhalten: \(remainingPath)")
            return false
        }
        afterQuarantine?(cleanupDirectory)
        removeOwnedTempDirectory(
            cleanupDirectory,
            expectedIdentity: cleanupIdentity,
            expectedOwnerPID: ownerPID,
            expectedCleanupEntry: entryRecord
        )
        if captureSnapshot(of: cleanupDirectory) != .missing {
            log("⚠️ Cleanup-Rest bleibt bis zum nächsten Lauf liegen: \(cleanupDirectory.path)")
        }
        // Der geprüfte Eintrag liegt nicht mehr unter seinem produktiven
        // Namen. Ein seltener Cleanup-Rest ist deshalb kein Commit-Fehler.
        return true
    }

    static func regularFileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int64 else { return nil }
        return size > 0 ? size : nil
    }

    static func mappedProgress(base: Double, weight: Double, phaseProgress: Double) -> Double {
        min(1, max(0, base + weight * min(1, max(0, phaseProgress))))
    }

    /// Setzt ein zuvor fehlendes Ziel mit `RENAME_EXCL` ein. Ein bestätigtes
    /// vorhandenes Ziel wird atomar mit der Staging-Datei getauscht; erst die
    /// danach tatsächlich verdrängte Datei wird gegen den Bestätigungs-Snapshot
    /// geprüft. Bei Abweichung tauscht die Funktion sofort zurück.
    @discardableResult
    static func commitStagedOutput(
        _ stagedURL: URL,
        to finalURL: URL,
        expectedDestination: OutputDestinationSnapshot,
        expectedDestinationDirectory: OutputDestinationSnapshot? = nil,
        expectedStagingOwnership: StagingOwnership? = nil,
        beforeRename: (() -> Void)? = nil,
        renameOperation: (URL, URL, UInt32) -> Int32 = {
            renameEntry(from: $0, to: $1, flags: $2)
        },
        unlinkDisplacedOutput: ((URL, FileSystemIdentity) -> Bool)? = nil
    ) throws -> Bool {
        guard case .existing(let expectedStagedIdentity) = captureSnapshot(of: stagedURL),
              expectedStagedIdentity.mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              expectedStagedIdentity.size > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let ownership = expectedStagingOwnership {
            guard stagingOwnershipMatches(
                ownership,
                identity: expectedStagedIdentity,
                at: stagedURL
            ) else {
                throw ConversionOutputError.stagingChanged(stagedURL)
            }
        }
        beforeRename?()
        if let expectedDestinationDirectory {
            try validateOutputDirectorySnapshot(
                for: finalURL,
                expected: expectedDestinationDirectory
            )
        }

        switch expectedDestination {
        case .missing:
            guard renameOperation(stagedURL, finalURL, UInt32(RENAME_EXCL)) == 0 else {
                let number = errno
                if number == EEXIST { throw ConversionOutputError.destinationChanged(finalURL) }
                throw POSIXError(POSIXErrorCode(rawValue: number) ?? .EIO)
            }
            guard case .existing(let movedIdentity) = captureSnapshot(of: finalURL),
                  expectedStagedIdentity.matchesDisplacedEntry(movedIdentity),
                  stagingOwnershipMatches(
                    expectedStagingOwnership,
                    identity: movedIdentity,
                    at: finalURL
                  ) else {
                guard renameOperation(finalURL, stagedURL, UInt32(RENAME_EXCL)) == 0 else {
                    let rollbackError = errno
                    let recoveryURL = preserveRecoveryEntry(
                        from: finalURL,
                        for: finalURL,
                        renameOperation: renameOperation
                    ) ?? finalURL
                    throw ConversionOutputError.restoreFailed(
                        finalURL,
                        recoveryURL: recoveryURL,
                        errno: rollbackError
                    )
                }
                throw ConversionOutputError.stagingChanged(stagedURL)
            }
            return true
        case .inaccessible(let number):
            throw ConversionOutputError.destinationInaccessible(finalURL, number)
        case .existing(let expectedIdentity):
            guard captureSnapshot(of: finalURL) == .existing(expectedIdentity) else {
                throw ConversionOutputError.destinationChanged(finalURL)
            }
            guard expectedIdentity.mode & mode_t(S_IFMT) != mode_t(S_IFDIR) else {
                throw ConversionOutputError.destinationIsDirectory(finalURL)
            }
            if let ownership = expectedStagingOwnership,
               let protectedDirectory = ownership.protectedDirectory,
               let protectedIdentity = ownership.protectedDirectoryIdentity {
                guard let currentDirectory = fileSystemIdentity(
                    at: protectedDirectory,
                    followSymlink: false
                ),
                protectedIdentity.matchesDirectoryEntry(currentDirectory),
                temporaryDirectoryOwnerPID(protectedDirectory)
                    == ownership.ownerPID else {
                    throw ConversionOutputError.stagingChanged(stagedURL)
                }
                // Direkt nach RENAME_SWAP enthält entry.m4b das alte Ziel.
                // Ein Absturz in diesem Fenster darf den Staging-Ordner beim
                // nächsten Lauf trotzdem eindeutig als aufräumbar erkennen.
                try writeCleanupEntryIdentity(
                    ownership.identity,
                    in: protectedDirectory,
                    filename: stagedURL.lastPathComponent,
                    stableIdentityOnly: true,
                    alternateIdentity: expectedIdentity,
                    alternateStableIdentityOnly: false
                )
            }
            guard renameOperation(stagedURL, finalURL, UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let movedStagingMatches: Bool
            if case .existing(let movedIdentity) = captureSnapshot(of: finalURL) {
                movedStagingMatches = expectedStagedIdentity
                    .matchesDisplacedEntry(movedIdentity)
                    && stagingOwnershipMatches(
                        expectedStagingOwnership,
                        identity: movedIdentity,
                        at: finalURL
                    )
            } else {
                movedStagingMatches = false
            }
            let displacedDestinationMatches: Bool
            if case .existing(let displacedIdentity) = captureSnapshot(of: stagedURL) {
                displacedDestinationMatches = expectedIdentity
                    .matchesDisplacedEntry(displacedIdentity)
            } else {
                displacedDestinationMatches = false
            }
            guard movedStagingMatches, displacedDestinationMatches else {
                guard renameOperation(stagedURL, finalURL, UInt32(RENAME_SWAP)) == 0 else {
                    let rollbackError = errno
                    let recoveryURL = preserveRecoveryEntry(
                        from: stagedURL,
                        for: finalURL,
                        renameOperation: renameOperation
                    ) ?? stagedURL
                    throw ConversionOutputError.restoreFailed(
                        finalURL,
                        recoveryURL: recoveryURL,
                        errno: rollbackError
                    )
                }
                if !movedStagingMatches {
                    throw ConversionOutputError.stagingChanged(stagedURL)
                }
                throw ConversionOutputError.destinationChanged(finalURL)
            }
            // Das bestätigte alte Ziel liegt jetzt unter dem eindeutigen
            // Staging-Namen. `unlink` entfernt nur diesen Eintrag, nie rekursiv.
            return unlinkDisplacedOutput?(stagedURL, expectedIdentity)
                ?? removeDisplacedOutput(
                    stagedURL,
                    expectedIdentity: expectedIdentity,
                    cleanupParent: finalURL.deletingLastPathComponent()
                )
        }
    }

    static func splitAudioFilesIfNeeded(_ files: [AudioFile], maxDurationHours: Int?) -> [[AudioFile]] {
        guard let maxHours = maxDurationHours, maxHours > 0 else { return [files] }
        var result: [[AudioFile]] = []; var currentGroup: [AudioFile] = []; var currentDuration: TimeInterval = 0
        for file in files {
            if currentDuration + file.duration <= Double(maxHours) * 3600 {
                currentGroup.append(file); currentDuration += file.duration
            } else {
                if !currentGroup.isEmpty { result.append(currentGroup) }
                currentGroup = [file]; currentDuration = file.duration
            }
        }
        if !currentGroup.isEmpty { result.append(currentGroup) }
        return result
    }


    @discardableResult
    public static func cancelConversion(
        session: ConversionSession
    ) -> ConversionCancellationOutcome {
        guard let context = session.currentConversionContext() else {
            return session.hasFinishedConversion()
                ? .rejected
                : .noActiveConversion
        }
        guard context.cancel(onAccepted: {
            session.enqueueCancellationStarted(runID: context.id)
        }) else { return .rejected }
        return .cancelled
    }

    static func createOwnedTempDirectory(
        _ url: URL,
        ownerPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) throws {
        let created = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return Darwin.mkdir(path, mode_t(0o700))
        }
        guard created == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let owner = String(ownerPID)
        do {
            try owner.write(
                to: url.appendingPathComponent(tempOwnerFilename),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            // Das exklusiv erzeugte Blatt ist bei fehlgeschlagenem Marker noch
            // leer. `rmdir` kann deshalb keine untergeschobenen Inhalte löschen.
            _ = removeEmptyDirectory(url)
            throw error
        }
    }

    static func temporaryDirectoryOwnerPID(_ url: URL) -> pid_t? {
        let marker = url.appendingPathComponent(tempOwnerFilename)
        guard let text = try? String(contentsOf: marker, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return nil }
        return pid_t(pid)
    }

    private static func temporaryDirectoryOwnerPID(
        descriptor: Int32
    ) -> pid_t? {
        let markerDescriptor = tempOwnerFilename.withCString {
            Darwin.openat(
                descriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard markerDescriptor >= 0 else { return nil }
        defer { _ = Darwin.close(markerDescriptor) }
        var information = stat()
        guard Darwin.fstat(markerDescriptor, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_size > 0,
              information.st_size <= 32 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(information.st_size))
        let count = bytes.withUnsafeMutableBytes {
            Darwin.read(markerDescriptor, $0.baseAddress, $0.count)
        }
        guard count == bytes.count,
              let text = String(bytes: bytes, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return nil }
        return pid_t(pid)
    }

    static func temporaryDirectoryHasLiveOwner(_ url: URL) -> Bool {
        guard let pid = temporaryDirectoryOwnerPID(url) else { return false }
        return Darwin.kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    /// Entfernt Inhalte ausschließlich relativ zu einem geöffneten
    /// Verzeichnis-Deskriptor. Weder Symlinks noch ein später am sichtbaren Pfad
    /// eingesetztes Ersatzverzeichnis werden dabei rekursiv verfolgt.
    private static func removeDirectoryContentsBound(to descriptor: Int32) -> Bool {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, let stream = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            return false
        }
        defer { Darwin.closedir(stream) }
        let directoryDescriptor = Darwin.dirfd(stream)

        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else { return errno == 0 }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }

            var information = stat()
            let inspected = name.withCString {
                Darwin.fstatat(
                    directoryDescriptor,
                    $0,
                    &information,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard inspected == 0 else { return false }
            if information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                let child = name.withCString {
                    Darwin.openat(
                        directoryDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard child >= 0 else { return false }
                let emptied = removeDirectoryContentsBound(to: child)
                _ = Darwin.close(child)
                guard emptied,
                      name.withCString({
                          Darwin.unlinkat(directoryDescriptor, $0, AT_REMOVEDIR)
                      }) == 0 else { return false }
            } else {
                guard name.withCString({
                    Darwin.unlinkat(directoryDescriptor, $0, 0)
                }) == 0 else { return false }
            }
        }
    }

    private static func cleanupEntryMatchesRecordedIdentity(
        _ record: CleanupEntryRecord,
        directoryDescriptor: Int32
    ) -> Bool {
        var information = stat()
        let result = record.filename.withCString {
            Darwin.fstatat(
                directoryDescriptor,
                $0,
                &information,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result != 0 { return errno == ENOENT }
        let current = FileSystemIdentity(stat: information)
        return record.matches(current)
    }

    private static func directoryEntryNames(
        descriptor: Int32
    ) -> [String]? {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, let stream = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            return nil
        }
        defer { Darwin.closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                return errno == 0 ? names : nil
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
    }

    /// Entfernt aus einem Ausgabe-Cleanup-Ordner ausschließlich die drei
    /// aufgezeichneten Einträge. Zusätzliche Dateien sind Recovery-Daten und
    /// verhindern jede automatische Löschung des Ordners.
    private static func removeRecordedCleanupContentsBound(
        descriptor: Int32,
        record: CleanupEntryRecord,
        beforeEntryQuarantine: ((Int32) -> Void)? = nil
    ) -> Bool {
        guard let names = directoryEntryNames(descriptor: descriptor) else {
            return false
        }
        // Der feste Zwischenname ist Teil des Crash-Protokolls: Stirbt der
        // Prozess nach dem Rename, erkennt der nächste Sweep genau diesen
        // Zustand und prüft dessen Inode erneut gegen denselben Datensatz.
        let quarantineName = ".HB_EntryCleanup"
        let allowed = Set([
            tempOwnerFilename,
            cleanupEntryIdentityFilename,
            record.filename,
            quarantineName
        ])
        let hasEntry = names.contains(record.filename)
        let hasQuarantine = names.contains(quarantineName)
        guard Set(names).isSubset(of: allowed),
              !(hasEntry && hasQuarantine) else { return false }

        var movedDuringThisCall = false
        if hasEntry {
            guard cleanupEntryMatchesRecordedIdentity(
                record,
                directoryDescriptor: descriptor
            ) else { return false }
            beforeEntryQuarantine?(descriptor)
            let quarantined = record.filename.withCString { source in
                quarantineName.withCString { destination in
                    Darwin.renameatx_np(
                        descriptor,
                        source,
                        descriptor,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard quarantined == 0 else { return false }
            movedDuringThisCall = true
        }
        if hasEntry || hasQuarantine {
            var movedInformation = stat()
            let inspected = quarantineName.withCString {
                Darwin.fstatat(
                    descriptor,
                    $0,
                    &movedInformation,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard inspected == 0,
                  record.matches(FileSystemIdentity(stat: movedInformation)) else {
                // Der Name wurde nach der Vorprüfung ausgetauscht. Der atomar
                // quarantänisierte fremde Eintrag wird zurückgestellt; falls
                // dort inzwischen wieder etwas liegt, bleibt er unter dem
                // aufgezeichneten Recovery-Zwischennamen erhalten.
                if movedDuringThisCall {
                    _ = quarantineName.withCString { source in
                        record.filename.withCString { destination in
                            Darwin.renameatx_np(
                                descriptor,
                                source,
                                descriptor,
                                destination,
                                UInt32(RENAME_EXCL)
                            )
                        }
                    }
                }
                return false
            }
            guard quarantineName.withCString({
                Darwin.unlinkat(descriptor, $0, 0)
            }) == 0 else { return false }
        }
        for marker in [cleanupEntryIdentityFilename, tempOwnerFilename]
        where names.contains(marker) {
            guard marker.withCString({
                Darwin.unlinkat(descriptor, $0, 0)
            }) == 0 else { return false }
        }
        return directoryEntryNames(descriptor: descriptor)?.isEmpty == true
    }

    static func removeOwnedTempDirectory(
        _ url: URL,
        expectedIdentity: FileSystemIdentity,
        expectedOwnerPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        beforeQuarantine: (() -> Void)? = nil,
        beforeBoundRemoval: (() -> Void)? = nil,
        beforeRecordedEntryQuarantine: ((Int32) -> Void)? = nil,
        expectedCleanupEntry: CleanupEntryRecord? = nil
    ) {
        guard let currentIdentity = fileSystemIdentity(at: url, followSymlink: false),
              expectedIdentity.matchesDirectoryEntry(currentIdentity),
              temporaryDirectoryOwnerPID(url) == expectedOwnerPID else { return }
        beforeQuarantine?()

        let quarantine = url.deletingLastPathComponent().appendingPathComponent(
            ".HB_Cleanup_\(expectedOwnerPID)-\(UUID().uuidString)"
        )
        guard renameEntry(
            from: url,
            to: quarantine,
            flags: UInt32(RENAME_EXCL)
        ) == 0 else { return }

        guard let movedIdentity = fileSystemIdentity(
            at: quarantine,
            followSymlink: false
        ),
        expectedIdentity.matchesDirectoryEntry(movedIdentity),
        temporaryDirectoryOwnerPID(quarantine) == expectedOwnerPID else {
            // Der Pfad wurde nach der Vorprüfung ausgetauscht. Den fremden
            // Eintrag atomar an seinen ursprünglichen Namen zurückstellen; bei
            // einem weiteren Rennen bleibt er sicher unter dem Quarantänenamen.
            _ = renameEntry(
                from: quarantine,
                to: url,
                flags: UInt32(RENAME_EXCL)
            )
            return
        }
        beforeBoundRemoval?()
        let descriptor = openOwnedDirectory(quarantine)
        guard descriptor >= 0 else { return }
        var boundInformation = stat()
        let boundMatches = Darwin.fstat(descriptor, &boundInformation) == 0
            && expectedIdentity.device == boundInformation.st_dev
            && expectedIdentity.inode == boundInformation.st_ino
            && boundInformation.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        guard boundMatches else {
            _ = Darwin.close(descriptor)
            return
        }
        if let expectedCleanupEntry {
            let emptied = removeRecordedCleanupContentsBound(
                descriptor: descriptor,
                record: expectedCleanupEntry,
                beforeEntryQuarantine: beforeRecordedEntryQuarantine
            )
            guard emptied else {
                // Der gebundene Ordner enthält zusätzliche oder ausgetauschte
                // Recovery-Daten. Die Besitzerdatei bleibt erhalten, damit ein
                // späterer Lauf den eigenen Rest erneut prüfen kann.
                _ = Darwin.close(descriptor)
                return
            }
            _ = Darwin.close(descriptor)
            _ = removeEmptyDirectory(quarantine)
            return
        }
        let emptied = removeDirectoryContentsBound(to: descriptor)
        _ = Darwin.close(descriptor)
        guard emptied else { return }
        // `rmdir` ist absichtlich nicht rekursiv: Wurde der sichtbare Pfad nach
        // dem gebundenen Leeren ausgetauscht, bleibt ein Ersatz mit Inhalt stehen.
        _ = removeEmptyDirectory(quarantine)
    }

    public static func cleanupOldTempDirectories() {
        cleanupOldTempDirectories(
            in: URL(fileURLWithPath: NSTemporaryDirectory()),
            now: Date()
        )
    }

    static func cleanupOldTempDirectories(in tempDir: URL, now: Date) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.creationDateKey], options: []) else { return }
        let oneDayAgo = now.addingTimeInterval(-24 * 3600)
        
        for url in contents {
            let name = url.lastPathComponent
            let isTempName = name.hasPrefix("HB_Temp_")
                && UUID(uuidString: String(name.dropFirst("HB_Temp_".count))) != nil
            let cleanupSuffix = name.hasPrefix(".HB_Cleanup_")
                ? String(name.dropFirst(".HB_Cleanup_".count)) : ""
            let cleanupParts = cleanupSuffix.split(separator: "-", maxSplits: 1)
            let cleanupOwner = cleanupParts.first.flatMap { pid_t($0) }
            let isCleanupName = cleanupParts.count == 2
                && cleanupOwner != nil
                && UUID(uuidString: String(cleanupParts[1])) != nil
            guard (isTempName || isCleanupName),
                  let resourceValues = try? url.resourceValues(forKeys: [.creationDateKey]),
                  let creationDate = resourceValues.creationDate,
                  creationDate < oneDayAgo,
                  let identity = fileSystemIdentity(at: url, followSymlink: false),
                  identity.mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  let owner = temporaryDirectoryOwnerPID(url),
                  !isCleanupName || cleanupOwner == owner else { continue }
            // Nur ESRCH beweist, dass der markierte Besitzer nicht mehr lebt.
            guard Darwin.kill(owner, 0) != 0, errno == ESRCH else { continue }
            removeOwnedTempDirectory(
                url,
                expectedIdentity: identity,
                expectedOwnerPID: owner
            )
        }
    }

    static func timeToSeconds(_ time: String) -> TimeInterval? {
        let parts = time.split(separator: ":")
        if parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) {
            return (h * 3600) + (m * 60) + s
        }
        return nil
    }

    static func extractTimeFromFFmpeg(_ output: String) -> String? {
        extractTimesFromFFmpeg(output).last
    }

    static func extractTimesFromFFmpeg(_ output: String) -> [String] {
        let pattern = "time=(\\d{2}:\\d{2}:\\d{2}\\.\\d{2})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(
            in: output,
            range: NSRange(output.startIndex..., in: output)
        ).compactMap { match in
            Range(match.range(at: 1), in: output).map { String(output[$0]) }
        }
    }

    private static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

extension FFmpegWrapper {
    static func ffmpegTimeArgument(_ seconds: TimeInterval) -> String {
        String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            seconds
        )
    }

    static func getArgsForStandardSlicing(
        file: AudioFile,
        url: URL,
        settings: AudioSettings
    ) -> [String] {
        // Zwischen-WAV direkt auf die Ziel-Abtastrate slicen statt hart auf 44100.
        // Sonst würde z.B. bei Ziel 48000 zweimal resampelt (Quelle→44100 beim
        // Slicen, 44100→48000 beim finalen Encode) — unnötiger Qualitätsverlust.
        // Ebenso auf die Ziel-KANALZAHL slicen (nicht hart Stereo): unkomprimiertes
        // WAV ist der Temp-Treiber (Standard-Modus hält ALLE Slices gleichzeitig),
        // und für ein Mono-Hörbuch (Default) halbiert Mono-Slicing den Temp-Bedarf.
        // Der finale `-ac`-Downmix bleibt identisch, nur eben schon beim Slicen.
        return ["-nostdin", "-y", "-ss", ffmpegTimeArgument(file.startTime), "-t", ffmpegTimeArgument(file.duration), "-i", file.url.path, "-vn", "-acodec", "pcm_s16le", "-ar", "\(settings.sampleRate)", "-ac", settings.isMono ? "1" : "2", url.path]
    }

    static func getArgsForParallelEncoding(
        file: AudioFile,
        url: URL,
        settings: AudioSettings
    ) -> [String] {
        return ["-nostdin", "-y", "-ss", ffmpegTimeArgument(file.startTime), "-t", ffmpegTimeArgument(file.duration), "-i", file.url.path, "-vn", "-c:a", "aac_at", "-aac_at_mode", "cvbr", "-b:a", settings.bitrate, "-ar", "\(settings.sampleRate)", "-ac", settings.isMono ? "1" : "2", url.path]
    }
}
