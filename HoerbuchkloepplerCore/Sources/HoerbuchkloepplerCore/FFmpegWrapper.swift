import Foundation
import AVFoundation
import CoreMedia
import ImageIO
import Darwin

// Kodierpipeline und Laufsteuerung: Ausgabeplan, laufbezogener Besitz von
// Prozessen und Zwischendateien, Segment- und Muxing-Schritte. Die
// Prozessmechanik steht in ProcessTermination.swift, die Dateisystemgrenze in
// OutputStaging.swift.

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
    private var segmentFailure = false
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
        guard !cancelled && !segmentFailure else {
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

    var hasSegmentFailure: Bool {
        lock.lock()
        defer { lock.unlock() }
        return segmentFailure
    }

    /// Stoppt nach einem fatalen Fehler alle besessenen Prozesse, ohne einen
    /// Benutzerabbruch vorzutäuschen. Neue Starts prüfen dieselbe Sperre.
    func failSegments() {
        lock.lock()
        guard !segmentFailure else { lock.unlock(); return }
        segmentFailure = true
        let running = Array(processes)
        lock.unlock()
        ProcessTerminator.terminateAndWait(running)
    }

    /// Hebt das Fehler-Latch eines abgeschlossenen Teilschritts wieder auf.
    /// Nur für einen Schritt gedacht, der allein scheitern darf: Der
    /// Lautheits-Analysepass läuft vor der eigentlichen Kodierung und hat den
    /// Kontext in dieser Zeit für sich.
    func clearSegmentFailure() {
        lock.lock()
        segmentFailure = false
        lock.unlock()
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
        // Auch ohne laufenden Prozess gehört die Bereinigung auf die
        // Hintergrundqueue: Sie löscht Zwischendateien rekursiv, und
        // `cancelConversion` wird aus dem Overlay-Knopf und aus
        // `beginConversionRun` heraus auf dem Main Actor gerufen. Bei leerer
        // Zielliste kehrt `terminateAndWait` sofort zurück, der Umweg kostet
        // also nichts.
        ProcessTerminator.terminateInBackground(
            terminationRequest,
            completion: finishCleanup
        )
        return true
    }

    /// Reiht den terminalen Worker-Event erst nach einer bereits laufenden
    /// Abbruchbereinigung ein. Ohne diese Barriere könnte der Main Actor den
    /// Lauf beenden und nachfolgende Bereinigungswarnungen als veraltet löschen.
    func finishAfterCancellationCleanup(
        _ action: @Sendable (Bool) -> Void
    ) {
        let wasCancelled = completeAfterCancellationCleanup(until: nil) ?? false
        action(wasCancelled)
    }

    /// Gemeinsame Barriere für Worker-Abschluss und Tests. Ein erfolgreicher
    /// Durchlauf markiert den Kontext zugleich als beendet; das ist derselbe
    /// Zustandswechsel wie in `finishAfterCancellationCleanup`.
    private func completeAfterCancellationCleanup(until deadline: Date?) -> Bool? {
        lock.lock()
        while cancellationCleanupInProgress {
            if let deadline {
                guard lock.wait(until: deadline) else {
                    lock.unlock()
                    return nil
                }
            } else {
                lock.wait()
            }
        }
        finished = true
        let wasCancelled = cancelled
        lock.unlock()
        return wasCancelled
    }

    #if DEBUG
    /// Begrenzte Testbarriere ohne einen bei Timeout zurückbleibenden Thread.
    func waitForCancellationCleanup(timeout: TimeInterval = 5) -> Bool {
        let bounded = timeout.isFinite ? max(0, timeout) : 5
        return completeAfterCancellationCleanup(
            until: Date(timeIntervalSinceNow: bounded)
        ) != nil
    }
    #endif
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
    let narrator: String
    let series: String
    let volumeNumber: String
    let language: String
    let coverData: Data?
    var loudnessGain: Double = 0
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

final class ParallelProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var progresses: [Int: Double] = [:]
    private let durations: [Double]
    init(durations: [Double]) { self.durations = durations }

    /// Gesamtfortschritt nach Dauer gewichtet; die Anzahl der Segmente
    /// spielt seit der Umstellung auf Dauergewichtung keine Rolle mehr.
    func update(index: Int, progress: Double) -> Double {
        lock.lock()
        progresses[index] = max(progresses[index] ?? 0, min(1, max(0, progress)))
        let duration = durations.reduce(0, +)
        let total = duration > 0 ? progresses.reduce(0.0) { sum, item in
            sum + item.value * durations[item.key] / duration
        } : 0
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
    static let maximumCoverByteCount = 32 * 1024 * 1024

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
        // Gemeinsames Inhaltsprädikat statt eines eigenen Feldvergleichs; die
        // gelesene Bytezahl gegen `st_size` bleibt als eigene Zusicherung daneben.
        guard data.count <= maximumCoverByteCount,
              data.count == Int(before.st_size),
              Darwin.fstat(descriptor, &after) == 0,
              FileSystemIdentity(stat: before).matchesContentSnapshot(FileSystemIdentity(stat: after)),
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
        convert(session: session, plan: plan, measureBookLoudness: nil)
    }

    /// `measureBookLoudness` ist eine Testnaht: Der echte Messpass startet
    /// einen vollständigen Dekodierlauf über das ganze Buch und lässt sich
    /// sonst weder zum Fehlschlag noch zum Abbruch bringen.
    @MainActor
    @discardableResult
    static func convert(
        session: ConversionSession,
        plan: ConversionPlan,
        measureBookLoudness: (@Sendable () throws -> LoudnessMeasurement)?
    ) -> ConversionStartResult {
        let outputLanguage: String
        do {
            outputLanguage = try BookMetadata.outputLanguage(session.language)
            try BookMetadata.validateVolumeNumber(session.volumeNumber)
        } catch { return .rejected(error.localizedDescription) }
        session.refreshProjectSourceIssues()
        guard session.projectSourceIssues.isEmpty else {
            return .rejected("Projektquellen fehlen oder wurden verändert.")
        }
        // Ohne Eingabedateien gar nicht erst starten — sonst leere ffmpeg-Liste
        // und Division durch die Gruppengröße bei der Fortschrittsberechnung.
        guard !plan.groups.isEmpty,
              plan.groups.allSatisfy({ !$0.isEmpty }),
              plan.groups.count == plan.outputURLs.count else {
            return reject(
                session: session,
                status: "Keine Dateien",
                message: "Keine Audiodateien zum Konvertieren vorhanden."
            )
        }
        let outputLeases: OutputLeaseSet
        do {
            try validateConversionPlan(plan)
            outputLeases = try acquireOutputLeases(for: plan.outputURLs)
        } catch {
            return reject(
                session: session,
                status: "Ausgabe nicht sicher verfügbar",
                message: error.localizedDescription
            )
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
            narrator: session.narrator, series: session.series,
            volumeNumber: session.volumeNumber, language: outputLanguage,
            // Ein manuell gewähltes Cover wird ausschließlich aus dem beim
            // Auswählen gelesenen Snapshot kodiert. Der sichtbare Pfad bleibt
            // nur UI-Metadatum und darf den Inhalt später nicht austauschen.
            coverData: coverSnapshotForConversion(session)
        )
        let plannedTotalDuration = plannedFiles.reduce(0) { $0 + $1.duration }
        // Zwischen `beginConversionRun()` und hier liegt kein Suspendierungspunkt
        // — `convert` ist Main-Actor-isoliert und nicht `async`. Der Kontext ist
        // deshalb zwangsläufig der aktuelle; eine Prüfung wäre toter Code, der
        // Sperren und Kontext ungeschlossen zurückließe.
        session.runState = ConversionRunState(startingWith: "Konvertierung läuft")
        session.eventLogs = []
        session.logString = ""
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
            var job = job
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

            if job.settings.analyzeLoudness || job.settings.normalizeLoudness {
                do {
                    let measurement = try measureBookLoudness?()
                        ?? analyzeBookLoudness(job: job, session: session, context: context)
                    job.loudnessGain = job.settings.normalizeLoudness ? measurement.gainDB : 0
                    session.enqueueLog(measurement.description + (job.settings.normalizeLoudness ? "; gemeinsamer Gain: \(job.loudnessGain) dB" : "; Analyse ohne Pegeländerung"), type: .info, runID: context.id)
                } catch {
                    if context.isCancelled || job.settings.normalizeLoudness {
                        // Wer „Lautheit angleichen" gewählt hat, will die
                        // Pegeländerung. Ein Buch ohne sie still auszuliefern
                        // wäre etwas anderes als das Bestellte.
                        overallSuccess = false
                        if !context.isCancelled { session.enqueueLog("Lautheitsanalyse fehlgeschlagen: \(error.localizedDescription)", type: .highlight, runID: context.id) }
                    } else {
                        // Die reine Analyse ist eine Auskunft. Sie darf die
                        // Konvertierung nicht kosten — auch nicht über das
                        // Fehler-Latch, das ihr eigener Dekodierpass gesetzt
                        // haben kann und das sonst jeden weiteren Prozessstart
                        // dieses Laufs stumm ablehnte.
                        context.clearSegmentFailure()
                        session.enqueueLog("Lautheitsanalyse fehlgeschlagen, die Konvertierung läuft ohne Messwert weiter: \(error.localizedDescription)", type: .highlight, runID: context.id)
                    }
                }
            }
            for (groupIndex, fileGroup) in (overallSuccess ? job.plan.groups : []).enumerated() {
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
                                         workerLimit: Int,
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
        let maxConcurrent = max(1, min(workerLimit, group.count))
        let semaphore = DispatchSemaphore(value: maxConcurrent)
        let groupQueue = DispatchQueue(label: "com.hoerbuchkloppler.parallel", attributes: .concurrent)
        let completionGroup = DispatchGroup()
        
        let results = ParallelResults(count: group.count)
        let tracker = ParallelProgressTracker(durations: group.map(\.duration))
        let itemCount = group.count

        session.enqueueSegmentReset(
            title: showIndividualPacmans ? nil : "Audio-Dekodierung (WAV)",
            phase: showIndividualPacmans ? .encoding : .decoding,
            runID: context.id
        )

        for (idx, file) in group.enumerated() {
            // Vor dem Einreihen warten: auch die Dispatch-Warteschlange bleibt begrenzt.
            semaphore.wait()
            if context.isCancelled || context.hasSegmentFailure { semaphore.signal(); break }
            completionGroup.enter()
            groupQueue.async {
                var succeeded = false
                defer {
                    semaphore.signal()
                    completionGroup.leave()
                }
                defer { if !succeeded && !context.isCancelled { context.failSegments() } }

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
                                    progress: p
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
                    let stderrData = outputReader.waitUntilEOF(timeout: 0.25)
                    if context.isCancelled { return }
                    // Ein anderes Segment ist bereits fatal gescheitert und hat
                    // dieses per SIGTERM beendet (`failSegments`). Der so
                    // erzwungene Exit ist keine eigene Ursache und würde das Log
                    // nur mit Folgefehlern samt stderr-Auszug füllen.
                    if context.hasSegmentFailure { return }
                    if hadBackgroundProcesses {
                        session.enqueueLog(
                            "❌ Segment \(idx+1) ließ nach dem Werkzeug-Exit Hintergrundprozesse zurück; der Batch wird verworfen.",
                            type: .highlight,
                            runID: context.id
                        )
                        return
                    }
                    if outputReader.joinTimedOut {
                        session.enqueueLog(
                            "❌ Segment \(idx+1) lieferte keine vollständige Werkzeugausgabe; der Batch wird verworfen.",
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
                            succeeded = true
                            let finishedCount = results.store(segmentURL.path, at: idx)
                            let totalProgress = tracker.update(
                                index: idx,
                                progress: 1
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

    /// Schreibt die concat-Liste (`audio_list.txt`) und die FFMETADATA-
    /// Kapiteldatei (`chapters.txt`) nach tempDir. Gibt `false` zurück, wenn ein
    /// Schreibvorgang fehlschlägt — sonst liefe ffmpeg mit fehlender Steuerdatei
    /// weiter und meldete einen irreführenden Fehler. Pfade werden fürs
    /// concat-Format escaped (einfaches Anführungszeichen → `'\''`).
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
        outputPath: String
    ) -> [String] {
        var arguments = [
            "-nostdin", "-y", "-f", "concat", "-safe", "0", "-i", listFile.path,
            "-i", metaFile.path
        ]
        // Parallelmodus: Die fertig kodierten Segmente werden per concat nur
        // noch kopiert (`-c:a copy`). Ohne `-copyts` setzt ffmpeg die Zeitstempel
        // je Segment neu auf und die Kapitelmarken aus der FFMETADATA-Datei
        // verschieben sich gegen den Ton. Abnahme der Kapitelstarts beider Modi:
        // tests/verify_audio_transitions.py.
        if audioCodecArguments.contains("copy") { arguments += ["-copyts"] }
        if let coverInput { arguments += ["-i", coverInput] }
        arguments += audioCodecArguments
        arguments += [
            "-map", "0:a", "-map_metadata", "1",
            "-metadata", "title=\(job.title)",
            "-metadata", "album=\(job.title)",
            "-metadata", "artist=\(job.author)",
            "-metadata", "genre=\(job.genre)",
            "-metadata", "composer=\(job.narrator)",
            "-metadata", "grouping=\(job.series)",
            "-metadata", "disc=\(job.volumeNumber)",
            "-metadata", "language=\(job.language)",
            "-metadata:s:a:0", "language=\(job.language)"
        ]
        if coverInput != nil {
            arguments += ["-map", "2:0", "-c:v", "copy", "-disposition:v", "attached_pic"]
        }
        // Der MP4-Muxer leitet das Format sonst aus der Dateiendung ab. Der
        // Produktionspfad schreibt aber auf einen Dateideskriptor, deshalb muss
        // das Format ausdrücklich dabeistehen.
        arguments += ["-f", "ipod", outputPath]
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
        pacmanTitle: String,
        phase: ConversionPhase = .encoding
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
            phase: phase,
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
        let wavPaths = runParallelTasks(group: group, tempDir: tempDir, session: session, context: context, progressBase: progressBase, progressWeight: progressScale * 0.2, extensionStr: "wav", showIndividualPacmans: false, workerLimit: job.settings.effectiveWorkerLimit, inputSnapshots: job.plan.inputSnapshots) { _, file, url in
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
            ] + loudnessFilterArguments(gainDB: job.loudnessGain),
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
        let aacPaths = runParallelTasks(group: group, tempDir: tempDir, session: session, context: context, progressBase: progressBase, progressWeight: progressScale * 0.9, extensionStr: "m4a", showIndividualPacmans: true, workerLimit: job.settings.effectiveWorkerLimit, inputSnapshots: job.plan.inputSnapshots) { _, file, url in
            FFmpegWrapper.getArgsForParallelEncoding(
                file: file,
                url: url,
                settings: job.settings,
                gainDB: job.loudnessGain
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
            pacmanTitle: "Finaler Zusammenbau",
            phase: .muxing
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
        phase: ConversionPhase = .encoding,
        stagingURL: URL? = nil,
        expectedStagingOwnership: StagingOwnership? = nil,
        stagingHandle: StagingOutputHandle? = nil,
        beforeProcessStart: (() -> Void)? = nil,
        executableURL: URL? = nil
    ) -> Bool {
        session.enqueueSegmentReset(title: pacmanTitle, phase: phase, runID: context.id)
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
            let stderrData = outputReader.waitUntilEOF(timeout: 0.25)
            if context.isCancelled { return false }
            if hadBackgroundProcesses {
                session.enqueueLog(
                    "❌ KRITISCHER FEHLER: Werkzeug meldete Exit, ließ aber Hintergrundprozesse zurück. Die Ausgabe wird nicht übernommen.",
                    type: .highlight,
                    runID: context.id
                )
                return false
            }
            if outputReader.joinTimedOut {
                session.enqueueLog(
                    "❌ KRITISCHER FEHLER: Werkzeugausgabe blieb unvollständig. Die Ausgabe wird nicht übernommen.",
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

    static func mappedProgress(base: Double, weight: Double, phaseProgress: Double) -> Double {
        min(1, max(0, base + weight * min(1, max(0, phaseProgress))))
    }

    /// Lehnt eine Startanforderung ab und hinterlässt einen sauberen Zustand.
    /// Einen wirklich laufenden Vorgang fasst sie nicht an: Sonst verschwände
    /// dessen Overlay, während sein Worker weiterarbeitet.
    @MainActor
    private static func reject(
        session: ConversionSession,
        status: String,
        message: String
    ) -> ConversionStartResult {
        if session.currentConversionContext() == nil {
            session.runState = ConversionRunState(rejectedWith: status)
        }
        session.addLog("❌ \(message)", type: .highlight)
        return .rejected(message)
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
    private static func analyzeBookLoudness(job: ConversionJob, session: ConversionSession, context: ConversionContext) throws -> LoudnessMeasurement {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HB_Loudness_\(UUID().uuidString)")
        try createOwnedTempDirectory(folder)
        context.registerTempDirectory(folder)
        defer { context.removeTempDirectory(folder) }
        session.enqueueLog("Lautheitsanalyse: zusätzlicher vollständiger Dekodier- und Analysepass für das gesamte Buch; temporärer WAV-Bestand.", type: .info, runID: context.id)
        let files = job.plan.groups.flatMap { $0 }
        guard let paths = runParallelTasks(group: files, tempDir: folder, session: session, context: context, progressBase: 0, progressWeight: 0, extensionStr: "wav", showIndividualPacmans: false, workerLimit: job.settings.effectiveWorkerLimit, inputSnapshots: job.plan.inputSnapshots, argsProvider: { _, file, url in
            getArgsForStandardSlicing(file: file, url: url, settings: job.settings)
        }), let executable = getBinaryURL(name: "ffmpeg") else {
            throw NSError(domain: "Loudness", code: 2, userInfo: [NSLocalizedDescriptionKey: "Buchdekodierung fehlgeschlagen oder abgebrochen."])
        }
        session.enqueueSegmentReset(title: "Buchlautheit messen", phase: .measuringLoudness, runID: context.id)
        let list = folder.appendingPathComponent("analysis.txt")
        // Die erzeugten Segmentnamen liegen ausschließlich im eigenen UUID-Ordner.
        try paths.map { "file '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-nostdin", "-hide_banner", "-nostats", "-f", "concat", "-safe", "0", "-i", list.path, "-af", "loudnorm=I=-18:TP=-1:LRA=50:print_format=json", "-f", "null", "-"]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        let reader = ProcessPipeReader(handle: pipe.fileHandleForReading)
        defer { context.unregister(process) }
        guard try context.run(process) else { throw CancellationError() }
        try? pipe.fileHandleForWriting.close()
        reader.start()
        process.waitUntilExit()
        let background = ProcessTerminator.terminateRemainingOwnedGroup(process)
        let data = reader.waitUntilEOF(timeout: 0.25)
        if context.isCancelled { throw CancellationError() }
        guard !reader.joinTimedOut else {
            throw NSError(
                domain: "Loudness",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "ffmpeg-Lautheitsanalyse lieferte keine vollständige Werkzeugausgabe."]
            )
        }
        guard process.terminationStatus == 0, !background else {
            throw NSError(domain: "Loudness", code: 3, userInfo: [NSLocalizedDescriptionKey: "ffmpeg-Lautheitsanalyse fehlgeschlagen: \(String(decoding: data, as: UTF8.self))"])
        }
        try validateInputSnapshots(for: files, expected: job.plan.inputSnapshots)
        return try LoudnessMeasurement.parse(data)
    }
}
