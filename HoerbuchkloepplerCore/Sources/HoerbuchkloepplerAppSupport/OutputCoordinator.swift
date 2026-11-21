import AppKit
import Combine
import HoerbuchkloepplerCore
import UniformTypeIdentifiers

@MainActor
struct ExportBookmark {
    let files: [AudioFile]
    let settings: AudioSettings
    private let projectURL: URL?
    private let projectRevision: UUID
    private let metadata: BookMetadata
    private let coverImage: NSImage?
    private let coverPath: String?
    private let coverData: Data?
    private let coverSuppressed: Bool

    init(_ session: ConversionSession) {
        projectURL = session.loadedProjectURL
        projectRevision = session.projectRevision
        files = session.audioFiles
        settings = session.settings
        metadata = session.bookMetadata
        coverImage = session.coverImage
        coverPath = session.coverPath
        coverData = session.embeddedCoverData
        coverSuppressed = session.isCoverSuppressed
    }

    func matches(_ session: ConversionSession) -> Bool {
        projectURL == session.loadedProjectURL && projectRevision == session.projectRevision
            && files == session.audioFiles && settings == session.settings && metadata == session.bookMetadata
            && coverImage === session.coverImage && coverPath == session.coverPath
            && coverData == session.embeddedCoverData && coverSuppressed == session.isCoverSuppressed
    }
}

private struct PreparedExport {
    let bookmark: ExportBookmark
    let plan: ConversionPlan
    let preview: ConversionPreview
}

@MainActor
public final class OutputCoordinator: ObservableObject {
    public enum Activity: String {
        case preparingPreview = "Ausgabevorschau wird vorbereitet …"
        case checkingSources = "Projektquellen werden geprüft …"
        case preparingStart = "Export wird vorbereitet …"
    }

    @Published private var preparedExport: PreparedExport?
    @Published public private(set) var activity: Activity?
    @Published public var conversionStartError: String?
    public var preview: ConversionPreview? { preparedExport?.preview }
    private var confirmedPreview: PreparedExport?
    private var work: Task<Void, Never>?

    public init() {}

    public func selectOutput(session: ConversionSession, coverDrop: CoverDropCoordinator,
                             presentation: WindowPresentationCoordinator) {
        guard work == nil, preparedExport == nil, !session.isConverting,
              !session.isImporting, !coverDrop.isPending else { return }
        let bookmark = ExportBookmark(session)
        let panel = NSSavePanel()
        // Der Dateidialog muss dieselbe Endung vorschlagen wie der Export.
        panel.allowedContentTypes = [UTType(filenameExtension: "m4b") ?? .mpeg4Movie]
        panel.nameFieldStringValue = session.title.isEmpty ? "Hörbuch" : session.title
        panel.canCreateDirectories = true
        presentation.present(panel) { [weak self, weak presentation] response in
            guard response == .OK, let url = panel.url, let self, let presentation else { return }
            self.preparePreview(at: url, bookmark: bookmark, session: session,
                                coverDrop: coverDrop, presentation: presentation)
        }
    }

    func preparePreview(at url: URL, bookmark: ExportBookmark, session: ConversionSession,
                        coverDrop: CoverDropCoordinator, presentation: WindowPresentationCoordinator) {
        guard work == nil, preparedExport == nil, canProceed(bookmark, session: session, coverDrop: coverDrop) else { return }
        let destination = url.pathExtension.lowercased() == "m4b" ? url : url.appendingPathExtension("m4b")
        let files = bookmark.files
        let settings = bookmark.settings
        activity = .preparingPreview
        let worker = Task.detached(priority: .userInitiated) {
            let plan = FFmpegWrapper.makeConversionPlan(
                files: files, outputURL: destination, maxDurationHours: settings.maxDurationHours
            )
            return (plan, ConversionPreview(plan: plan, settings: settings))
        }
        work = Task { [weak self, weak presentation] in
            let (plan, preview) = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            self.finishWork()
            guard let presentation, self.canProceed(bookmark, session: session, coverDrop: coverDrop) else { return }
            self.preparedExport = PreparedExport(bookmark: bookmark, plan: plan, preview: preview)
            presentation.request(.conversionPreview) { [weak self, weak presentation] result in
                self?.finishPreview(result, session: session, coverDrop: coverDrop, presentation: presentation)
            }
        }
    }

    public func confirmPreview(_ ticket: UUID, session: ConversionSession, coverDrop: CoverDropCoordinator,
                               presentation: WindowPresentationCoordinator) {
        guard let sheet = presentation.sheet, sheet.id == ticket, sheet.kind == .conversionPreview, sheet.isPresented,
              let preparedExport, canProceed(preparedExport.bookmark, session: session, coverDrop: coverDrop) else { return }
        confirmedPreview = preparedExport
    }

    private func finishPreview(_ result: WindowSheetResult, session: ConversionSession,
                               coverDrop: CoverDropCoordinator, presentation: WindowPresentationCoordinator?) {
        let export = confirmedPreview
        preparedExport = nil
        confirmedPreview = nil
        guard result == .dismissed, let export, let presentation else { return }
        let collisions = export.plan.outputURLsRequiringOverwriteConfirmation
        if collisions.isEmpty {
            start(export, session: session, coverDrop: coverDrop)
        } else {
            presentation.present(.overwrite(filenames: collisions.map(\.lastPathComponent))) { [weak self] accepted in
                if accepted { self?.start(export, session: session, coverDrop: coverDrop) }
            }
        }
    }

    private func start(_ export: PreparedExport, session: ConversionSession, coverDrop: CoverDropCoordinator) {
        guard work == nil, canProceed(export.bookmark, session: session, coverDrop: coverDrop) else { return }
        let hasProject = session.loadedProjectURL != nil
        activity = hasProject ? .checkingSources : .preparingStart
        work = Task { [weak self] in
            do {
                if hasProject { try await session.verifyProjectSources() }
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishWork()
                self?.showStartResult(.rejected(error.localizedDescription))
                return
            }
            guard !Task.isCancelled else { return }
            guard self?.canProceed(export.bookmark, session: session, coverDrop: coverDrop) == true else {
                self?.finishWork()
                return
            }
            let result = await FFmpegWrapper.startVerifiedConversionAsync(session: session, plan: export.plan) {
                self?.isCurrent(export.bookmark, session: session, coverDrop: coverDrop) == true
            }
            guard !Task.isCancelled else { return }
            self?.finishWork()
            self?.showStartResult(result)
        }
    }

    public func cancelWork() {
        work?.cancel()
        finishWork()
    }

    private func finishWork() {
        work = nil
        activity = nil
    }

    private func canProceed(_ bookmark: ExportBookmark, session: ConversionSession, coverDrop: CoverDropCoordinator) -> Bool {
        guard isCurrent(bookmark, session: session, coverDrop: coverDrop) else {
            conversionStartError = "Das Hörbuch wurde geändert oder wird bearbeitet. Erstellen Sie die Ausgabevorschau erneut."
            return false
        }
        return true
    }

    private func isCurrent(_ bookmark: ExportBookmark, session: ConversionSession, coverDrop: CoverDropCoordinator) -> Bool {
        !session.isConverting && !session.isImporting && !session.isPreparingArtwork
            && !coverDrop.isPending && bookmark.matches(session)
    }

    private func showStartResult(_ result: ConversionStartResult) {
        switch result {
        case .started: conversionStartError = nil
        case .rejected(let message): conversionStartError = message
        }
    }

    deinit { work?.cancel() }
}
