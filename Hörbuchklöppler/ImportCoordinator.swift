import Foundation
import AppKit
import HoerbuchkloepplerCore

/// Provider erst sammeln: Anzahl gleichzeitiger Audioanalysen bleibt auch bei
/// großen Datei-Drops durch den gemeinsamen Importdienst begrenzt.
@MainActor
enum ImportCoordinator {
    @MainActor private final class ProviderCollection {
        private var results: [FileProviderItem?]
        private var remaining: Int
        private var continuation: CheckedContinuation<FileProviderImportResult, Never>?
        private var progress: [Progress] = []
        private var timer: Task<Void, Never>?

        init(count: Int) { results = Array(repeating: nil, count: count); remaining = count }

        func start(_ providers: [NSItemProvider], timeout: Duration, continuation: CheckedContinuation<FileProviderImportResult, Never>) {
            self.continuation = continuation
            guard !Task.isCancelled else { finish(.cancelled); return }
            timer = Task { [weak self] in
                do { try await Task.sleep(for: timeout) }
                catch { return }
                self?.finish(.timedOut)
            }
            for (index, provider) in providers.enumerated() {
                let operation = provider.loadObject(ofClass: URL.self) { [weak self] url, error in
                    let result: FileProviderItem = if let url, error == nil { .url(url) }
                        else { .failure(error?.localizedDescription) }
                    Task { @MainActor [weak self] in self?.receive(result, at: index) }
                }
                progress.append(operation)
            }
        }

        private func receive(_ result: FileProviderItem, at index: Int) {
            guard continuation != nil, results[index] == nil else { return }
            results[index] = result
            remaining -= 1
            if remaining == 0 { finish(.ready(results.compactMap { $0 })) }
        }

        func cancel() { finish(.cancelled) }

        private func finish(_ outcome: FileProviderImportResult) {
            guard let continuation else { return }
            self.continuation = nil
            timer?.cancel()
            timer = nil
            // Die Frist endet vor jeder Audioanalyse. Späte Provider-Callbacks
            // verlieren bereits vor dem Cancel ihre Schreibberechtigung.
            switch outcome {
            case .ready: break
            case .timedOut, .cancelled: progress.forEach { $0.cancel() }
            }
            progress = []
            continuation.resume(returning: outcome)
        }
    }

    static func importProviders(
        _ providers: [NSItemProvider],
        session: ConversionSession,
        timeout: Duration = .seconds(60),
        onTimeout: @escaping @MainActor ([NSItemProvider]) -> Void = { _ in }
    ) {
        guard !providers.isEmpty else { return }
        let collection = ProviderCollection(count: providers.count)
        session.startProviderImport(expectedItemCount: providers.count) {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    collection.start(providers, timeout: timeout, continuation: continuation)
                }
            } onCancel: {
                Task { @MainActor in collection.cancel() }
            }
        } onTimeout: {
            session.addLog("⏱️ Datei-Adressen nicht innerhalb der Wartefrist erhalten; neuer Import vollständig verworfen.")
            onTimeout(providers)
        }
    }

    static func importURLs(_ urls: [URL], session: ConversionSession) async {
        await session.importURLs(urls)
    }
}
