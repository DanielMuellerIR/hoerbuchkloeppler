import AppKit
import Combine
import HoerbuchkloepplerCore

@MainActor
final class CoverDropCoordinator: ObservableObject {
    @Published var errorMessage: String?
    private var request: UUID?
    private var progress: Progress?
    private var timeoutTask: Task<Void, Never>?
    private var coverObservation: AnyCancellable?

    func load(_ provider: NSItemProvider, session: ConversionSession, timeout: Duration = .seconds(60)) {
        cancel()
        errorMessage = nil
        let request = UUID()
        self.request = request
        coverObservation = session.coverSelectionChanges.sink { [weak self] _ in self?.cancel() }

        let deadline = ContinuousClock.now + timeout
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            guard let self, self.request == request else { return }
            self.cancel()
            self.errorMessage = "Die Cover-Datei wurde nicht rechtzeitig bereitgestellt. Ziehen Sie die Datei erneut auf das Cover-Feld."
        }

        progress = provider.loadObject(ofClass: URL.self) { [weak self, weak session] url, error in
            let failure = error?.localizedDescription
            Task { @MainActor in
                guard let self, self.request == request else { return }
                self.clearRequest()
                guard let session else { return }
                if let failure {
                    self.errorMessage = "Cover-Datei konnte nicht geladen werden: \(failure)"
                } else if let url, url.isFileURL {
                    if !session.selectCover(url: url) {
                        self.errorMessage = "Diese Datei ist kein lesbares Bild: \(url.lastPathComponent)"
                    }
                } else {
                    self.errorMessage = "Der Datei-Drop lieferte keine lesbare Cover-Datei."
                }
            }
        }
    }

    func cancel() {
        clearRequest()?.cancel()
    }

    @discardableResult
    private func clearRequest() -> Progress? {
        request = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        coverObservation = nil
        let progress = self.progress
        self.progress = nil
        return progress
    }

    deinit {
        timeoutTask?.cancel()
        progress?.cancel()
    }
}
