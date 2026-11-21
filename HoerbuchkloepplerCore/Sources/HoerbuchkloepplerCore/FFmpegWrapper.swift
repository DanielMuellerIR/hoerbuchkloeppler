import Foundation

// Einstieg in die Konvertierung und laufbezogener Besitz von Prozessen und Ausgaben.

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

    var canRunSegments: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled && !segmentFailure
    }

    /// Stoppt nach einem fatalen Fehler alle besessenen Prozesse, ohne einen
    /// Benutzerabbruch vorzutäuschen. Neue Starts prüfen dieselbe Sperre.
    @discardableResult
    func failSegments(onAccepted: () -> Void = {}) -> Bool {
        lock.lock()
        guard !cancelled, !segmentFailure else {
            lock.unlock()
            return false
        }
        segmentFailure = true
        let request = ProcessTerminator.makeTerminationRequest(for: Array(processes))
        lock.unlock()
        onAccepted()
        ProcessTerminator.terminateAndWait(request)
        return true
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
        guard let identity = FileSystemEntry.identity(at: url, followSymlink: false),
              identity.mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return }
        lock.lock()
        tempDirectories[url] = identity
        let shouldRemove = cancelled
        lock.unlock()
        if shouldRemove {
            OwnedTemporaryDirectory.remove(url, expectedIdentity: identity)
        }
    }

    func removeTempDirectory(_ url: URL) {
        lock.lock()
        let identity = tempDirectories.removeValue(forKey: url)
        lock.unlock()
        if let identity {
            OwnedTemporaryDirectory.remove(url, expectedIdentity: identity)
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
            return OutputCleanup.removeProtectedOutput(
                url,
                ownership: expectedOwnership,
                log: log
            )
        }
        return OutputCleanup.removeLegacyOutput(
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
            ?? OutputStaging.currentOwnership(at: url) else { return }
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
        guard !OutputCleanup.removeProtectedContainer(
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
            let removed = OutputCleanup.removeDisplacedOutput(
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
            let removed = OutputCleanup.removeDisplacedOutput(
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
                OwnedTemporaryDirectory.remove(
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
                let removed = OutputCleanup.removeDisplacedOutput(
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

/// Behält genug Byte-Kontext, um einen ffmpeg-Zeitwert auch dann zu erkennen,
/// wenn die Pipe ihn zwischen zwei Chunks trennt. Bei mehreren Statuszeilen
/// gewinnt der neueste statt des ersten Werts.
struct FFmpegProgressParser: Sendable {
    private var tail = Data()

    mutating func consume(_ chunk: Data) -> TimeInterval? {
        var combined = tail
        combined.append(chunk)
        let text = String(decoding: combined, as: UTF8.self)
        let result = FFmpegWrapper.extractTimesFromFFmpeg(text).last
            .flatMap(FFmpegWrapper.timeToSeconds)
        tail = Data(combined.suffix(64))
        return result
    }
}

public enum FFmpegWrapper {
    public static func makeConversionPlan(
        files: [AudioFile], outputURL: URL, maxDurationHours: Int?
    ) -> ConversionPlan {
        ConversionPlanner.makePlan(files: files, outputURL: outputURL, maxDurationHours: maxDurationHours)
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

    @MainActor
    public static func convertAsync(session: ConversionSession, plan: ConversionPlan) async -> ConversionStartResult {
        let settings = session.settings
        guard planMatchesSession(plan, session: session, requireCurrentGrouping: true), !session.isConverting else {
            return .rejected("Das Hörbuch wurde geändert oder wird bereits bearbeitet. Bitte erneut starten.")
        }
        do { try await session.verifyProjectSources() }
        catch { return .rejected(error.localizedDescription) }
        guard settings == session.settings else {
            return .rejected("Das Hörbuch wurde während der Prüfung verändert. Bitte erneut starten.")
        }
        return await startVerifiedConversionAsync(session: session, plan: plan)
    }

    /// Startet nach `verifyProjectSources()` oder ohne Projektquellen.
    /// Eine inzwischen veränderte oder ungeprüfte Quelle wird abgewiesen.
    @MainActor
    @discardableResult
    public static func startVerifiedConversion(session: ConversionSession, plan: ConversionPlan) -> ConversionStartResult {
        convert(session: session, plan: plan, measureBookLoudness: nil, cachedProjectSourcesOnly: true)
    }

    @MainActor
    public static func startVerifiedConversionAsync(
        session: ConversionSession, plan: ConversionPlan, confirmCurrent: () -> Bool = { true }
    ) async -> ConversionStartResult {
        let changed = "Das Hörbuch wurde geändert oder wird bereits bearbeitet. Bitte erneut starten."
        let projectRevision = session.projectRevision
        let settings = session.settings
        let metadata = session.bookMetadata
        let cover = session.embeddedCoverData
        func isCurrent() -> Bool {
            !session.isConverting && planMatchesSession(plan, session: session, requireCurrentGrouping: true)
                && projectRevision == session.projectRevision && settings == session.settings
                && metadata == session.bookMetadata && cover == session.embeddedCoverData && confirmCurrent()
        }

        guard isCurrent() else { return .rejected(changed) }
        let outputLanguage: String
        do { outputLanguage = try validatedOutputLanguage(session) }
        catch { return .rejected(error.localizedDescription) }
        do { try await session.verifyProjectSources(policy: .cachedOnly, plan: plan) }
        catch { return .rejected(error.localizedDescription) }
        guard isCurrent() else { return .rejected(changed) }
        guard session.projectSourceIssues.isEmpty else { return .rejected("Projektquellen fehlen oder wurden verändert.") }
        guard validGrouping(plan) else { return rejectEmpty(session) }

        let leases: OutputLeaseSet
        do {
            leases = try await performFileIO { try acquireOutputLeases(for: plan) }
        } catch is CancellationError {
            return .rejected("Der Start wurde abgebrochen.")
        } catch {
            guard isCurrent() else { return .rejected(changed) }
            return reject(session: session, status: "Ausgabe nicht sicher verfügbar", message: error.localizedDescription)
        }
        guard !Task.isCancelled else { return .rejected("Der Start wurde abgebrochen.") }
        if session.loadedProjectURL != nil {
            // Die Zielreservierung wartet auf Dateisystemzugriffe. Ein in
            // dieser Zeit umgelegter Quelllink darf selbst dann nicht in den
            // Lauf gelangen, wenn die geplante physische Datei noch existiert.
            do { try await session.verifyProjectSources(policy: .cachedOnly, plan: plan) }
            catch { return .rejected(error.localizedDescription) }
            guard session.projectSourceIssues.isEmpty else { return .rejected("Projektquellen fehlen oder wurden verändert.") }
        }
        guard isCurrent() else { return .rejected(changed) }
        return launch(session: session, plan: plan, outputLeases: leases, outputLanguage: outputLanguage,
                      measureBookLoudness: nil)
    }

    @MainActor
    private static func planMatchesSession(_ plan: ConversionPlan, session: ConversionSession, requireCurrentGrouping: Bool) -> Bool {
        guard !session.isImporting else { return false }
        if requireCurrentGrouping {
            return plan.groups == ConversionPlanner.splitAudioFilesIfNeeded(session.audioFiles, maxDurationHours: session.settings.maxDurationHours)
        }
        return plan.groups.flatMap { $0 } == session.audioFiles
    }

    /// `measureBookLoudness` ist eine Testnaht: Der echte Messpass startet
    /// einen vollständigen Dekodierlauf über das ganze Buch und lässt sich
    /// sonst weder zum Fehlschlag noch zum Abbruch bringen.
    @MainActor
    @discardableResult
    static func convert(
        session: ConversionSession,
        plan: ConversionPlan,
        measureBookLoudness: (@Sendable () throws -> LoudnessMeasurement)?,
        cachedProjectSourcesOnly: Bool = false,
        reserveOutputs: (ConversionPlan) throws -> OutputLeaseSet = acquireOutputLeases
    ) -> ConversionStartResult {
        guard !Task.isCancelled else { return .rejected("Der Start wurde abgebrochen.") }
        guard !session.isConverting else { return .rejected("Es läuft bereits eine Konvertierung.") }
        guard planMatchesSession(plan, session: session, requireCurrentGrouping: cachedProjectSourcesOnly) else {
            return .rejected("Das Hörbuch wurde geändert oder wird bereits bearbeitet. Bitte erneut starten.")
        }
        let outputLanguage: String
        do { outputLanguage = try validatedOutputLanguage(session) }
        catch { return .rejected(error.localizedDescription) }
        do {
            try session.refreshProjectSourceIssues(policy: cachedProjectSourcesOnly ? .cachedOnly : .synchronous, plan: plan)
        } catch is CancellationError { return .rejected("Der Start wurde abgebrochen.") }
        catch { return .rejected(error.localizedDescription) }
        guard session.projectSourceIssues.isEmpty else {
            return .rejected("Projektquellen fehlen oder wurden verändert.")
        }
        guard validGrouping(plan) else { return rejectEmpty(session) }
        let outputLeases: OutputLeaseSet
        do {
            outputLeases = try reserveOutputs(plan)
        } catch {
            return reject(
                session: session,
                status: "Ausgabe nicht sicher verfügbar",
                message: error.localizedDescription
            )
        }
        guard !Task.isCancelled else { return .rejected("Der Start wurde abgebrochen.") }
        if session.loadedProjectURL != nil {
            do { try session.refreshProjectSourceIssues(policy: .cachedOnly, plan: plan) }
            catch is CancellationError { return .rejected("Der Start wurde abgebrochen.") }
            catch { return .rejected(error.localizedDescription) }
            guard session.projectSourceIssues.isEmpty else { return .rejected("Projektquellen fehlen oder wurden verändert.") }
        }
        return launch(session: session, plan: plan, outputLeases: outputLeases, outputLanguage: outputLanguage,
                      measureBookLoudness: measureBookLoudness)
    }

    private static func validGrouping(_ plan: ConversionPlan) -> Bool {
        !plan.groups.isEmpty && plan.groups.allSatisfy { !$0.isEmpty } && plan.groups.count == plan.outputURLs.count
    }

    @MainActor
    private static func rejectEmpty(_ session: ConversionSession) -> ConversionStartResult {
        reject(session: session, status: "Keine Dateien", message: "Keine Audiodateien zum Konvertieren vorhanden.")
    }

    @MainActor
    private static func validatedOutputLanguage(_ session: ConversionSession) throws -> String {
        let language = try BookMetadata.outputLanguage(session.language)
        try BookMetadata.validateVolumeNumber(session.volumeNumber)
        return language
    }

    private static func acquireOutputLeases(for plan: ConversionPlan) throws -> OutputLeaseSet {
        try ConversionPlanner.validateConversionPlan(plan)
        try Task.checkCancellation()
        return try OutputLeases.acquire(for: plan.outputURLs)
    }

    @MainActor
    private static func launch(
        session: ConversionSession, plan: ConversionPlan, outputLeases: OutputLeaseSet, outputLanguage: String,
        measureBookLoudness: (@Sendable () throws -> LoudnessMeasurement)?
    ) -> ConversionStartResult {
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
        session.runState = ConversionRunState(startingWith: "Konvertierung läuft")
        session.eventLogs = []
        session.logString = ""
        let totalHours = Int(plannedTotalDuration / 3600)
        let totalMinutes = Int((plannedTotalDuration.truncatingRemainder(dividingBy: 3600)) / 60)
        let durationStr = String(format: "%02d:%02dh", totalHours, totalMinutes)
        let channels = job.settings.isMono ? "Mono" : "Stereo"

        var totalSize: Int64 = 0
        for snapshot in plan.inputSnapshots.values {
            if case .existing(let identity) = snapshot {
                let (sum, overflow) = totalSize.addingReportingOverflow(identity.size)
                totalSize = overflow ? Int64.max : sum
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

        ConversionPipeline(job: job, session: session, context: context).start(
            totalDuration: plannedTotalDuration,
            measureBookLoudness: measureBookLoudness
        )
        return .started
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
        session.addLog(message, type: .error)
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

    private static let progressTimePattern = try? NSRegularExpression(
        pattern: #"time=([0-9]{2,}:[0-9]{2}:[0-9]{2}\.[0-9]{2})"#
    )

    static func extractTimesFromFFmpeg(_ output: String) -> [String] {
        guard let regex = progressTimePattern else { return [] }
        return regex.matches(
            in: output,
            range: NSRange(output.startIndex..., in: output)
        ).compactMap { match in
            Range(match.range(at: 1), in: output).map { String(output[$0]) }
        }
    }

    static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
