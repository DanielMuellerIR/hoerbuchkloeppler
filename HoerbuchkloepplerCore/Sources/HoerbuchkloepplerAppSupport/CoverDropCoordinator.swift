import AppKit
import Combine
import HoerbuchkloepplerCore

@MainActor
public final class CoverDropCoordinator: ObservableObject {
    @Published public var errorMessage: String?
    @Published public private(set) var isPending = false
    private var request: UUID?
    private var progress: Progress?
    private var timeoutTask: Task<Void, Never>?
    private var preparation: Task<Void, Never>?
    private var coverObservation: AnyCancellable?
    private let prepareCover: @Sendable (URL) -> ConversionSession.PreparedCover?

    public init(prepareCover: @escaping @Sendable (URL) -> ConversionSession.PreparedCover? = {
        ConversionSession.PreparedCover(url: $0)
    }) {
        self.prepareCover = prepareCover
    }

    public func load(_ provider: NSItemProvider, session: ConversionSession, timeout: Duration = .seconds(60)) {
        cancel()
        errorMessage = nil
        let request = UUID()
        self.request = request
        isPending = true
        coverObservation = session.coverSelectionChanges.sink { [weak self] _ in self?.cancel() }

        let deadline = ContinuousClock.now + timeout
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            self?.expire(request)
        }

        progress = provider.loadObject(ofClass: URL.self) { [weak self, weak session] url, error in
            let failure = error?.localizedDescription
            Task { @MainActor in
                guard let self, self.request == request, self.preparation == nil, let session else { return }
                guard ContinuousClock.now < deadline else {
                    self.expire(request)
                    return
                }
                if let failure {
                    self.clearRequest()
                    self.errorMessage = "Cover-Datei konnte nicht geladen werden: \(failure)"
                } else if let url, url.isFileURL {
                    self.preparation = Task.detached(priority: .userInitiated) { [weak self, weak session, prepareCover = self.prepareCover] in
                        let cover = prepareCover(url)
                        guard !Task.isCancelled else { return }
                        await self?.finish(cover, url: url, request: request, deadline: deadline, session: session)
                    }
                } else {
                    self.clearRequest()
                    self.errorMessage = "Der Datei-Drop lieferte keine lesbare Cover-Datei."
                }
            }
        }
    }

    public func cancel() {
        clearRequest()?.cancel()
    }

    private func expire(_ request: UUID) {
        guard self.request == request else { return }
        cancel()
        errorMessage = "Die Cover-Datei konnte nicht rechtzeitig geladen werden. Ziehen Sie die Datei erneut auf das Cover-Feld."
    }

    private func finish(_ cover: ConversionSession.PreparedCover?, url: URL, request: UUID,
                        deadline: ContinuousClock.Instant, session: ConversionSession?) {
        guard self.request == request else { return }
        preparation = nil
        guard ContinuousClock.now < deadline else {
            expire(request)
            return
        }
        clearRequest()
        guard let session else { return }
        if let cover {
            session.selectCover(cover)
        } else {
            errorMessage = "Diese Datei ist kein lesbares Bild: \(url.lastPathComponent)"
        }
    }

    @discardableResult
    private func clearRequest() -> Progress? {
        request = nil
        if isPending { isPending = false }
        timeoutTask?.cancel()
        timeoutTask = nil
        preparation?.cancel()
        preparation = nil
        coverObservation = nil
        let progress = self.progress
        self.progress = nil
        return progress
    }

    deinit {
        timeoutTask?.cancel()
        preparation?.cancel()
        progress?.cancel()
    }
}
