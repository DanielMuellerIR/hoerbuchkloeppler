import Foundation
import AppKit
import HoerbuchkloepplerCore

/// Provider erst sammeln: Anzahl gleichzeitiger Audioanalysen bleibt auch bei
/// großen Datei-Drops durch den gemeinsamen Importdienst begrenzt.
@MainActor
enum ImportCoordinator {
    private enum ProviderResult: Sendable {
        case url(URL)
        case failure(String?)
    }

    private enum ProviderOutcome: Sendable {
        case ready([ProviderResult])
        case timedOut
        case cancelled
    }

    @MainActor private final class ProviderCollection {
        private var results: [ProviderResult?]
        private var remaining: Int
        private var continuation: CheckedContinuation<ProviderOutcome, Never>?
        private var progress: [Progress] = []
        private var timer: Task<Void, Never>?

        init(count: Int) { results = Array(repeating: nil, count: count); remaining = count }

        func start(_ providers: [NSItemProvider], timeout: Duration, continuation: CheckedContinuation<ProviderOutcome, Never>) {
            self.continuation = continuation
            guard !Task.isCancelled else { finish(.cancelled); return }
            timer = Task { [weak self] in
                do { try await Task.sleep(for: timeout) }
                catch { return }
                self?.finish(.timedOut)
            }
            for (index, provider) in providers.enumerated() {
                let operation = provider.loadObject(ofClass: URL.self) { [weak self] url, error in
                    let result: ProviderResult = if let url, error == nil { .url(url) }
                        else { .failure(error?.localizedDescription) }
                    Task { @MainActor [weak self] in self?.receive(result, at: index) }
                }
                progress.append(operation)
            }
        }

        private func receive(_ result: ProviderResult, at index: Int) {
            guard continuation != nil, results[index] == nil else { return }
            results[index] = result
            remaining -= 1
            if remaining == 0 { finish(.ready(results.compactMap { $0 })) }
        }

        func cancel() { finish(.cancelled) }

        private func finish(_ outcome: ProviderOutcome) {
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
        let providerCount = providers.count
        let token = session.beginImport(expectedItemCount: providerCount)
        let collection = ProviderCollection(count: providerCount)
        Task { @MainActor in
            await session.runImportTask(token) {
                let outcome = await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        collection.start(providers, timeout: timeout, continuation: continuation)
                    }
                } onCancel: {
                    Task { @MainActor in collection.cancel() }
                }
                guard !Task.isCancelled else { return }
                switch outcome {
                case .ready(let results):
                    var urls: [URL] = []
                    for (index, result) in results.enumerated() {
                        if case .url(let url) = result { urls.append(url); continue }
                        guard case .failure(let message) = result else { continue }
                        session.stageProviderLoadFailure(position: index + 1, total: providerCount,
                                                         errorDescription: message, importToken: token)
                        await session.finishImport(token)
                    }
                    await processURLs(urls, session: session, token: token)
                case .timedOut:
                    session.addLog("⏱️ Datei-Adressen nicht innerhalb der Wartefrist erhalten; neuer Import vollständig verworfen.")
                    session.cancelImport()
                    onTimeout(providers)
                case .cancelled:
                    break
                }
            }
        }
    }

    static func importURLs(_ urls: [URL], session: ConversionSession) async {
        let token = session.beginImport(expectedItemCount: urls.count)
        await session.runImportTask(token) { await processURLs(urls, session: session, token: token) }
    }

    private static func processURLs(_ urls: [URL], session: ConversionSession, token: ImportToken) async {
        var files: [FoundFile] = []
        for url in urls {
            guard !Task.isCancelled else { return }
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
                let scanned = await session.scanFolder(url, importToken: token)
                session.stageScannedFolder(scanned, importToken: token)
                await session.finishImport(token)
            } else if let found = ConversionSession.foundFile(at: url) { files.append(found) }
            else {
                session.stageAudioLoadResult(.failure(AudioImportFailure(sourceURL: url, reason: .analysisFailed)), importToken: token)
                await session.finishImport(token)
            }
        }
        let results = await session.loadAudioFiles(from: files, importToken: token)
        for result in results {
            session.stageAudioLoadResult(result, importToken: token)
            await session.finishImport(token, countingProgress: false)
        }
    }
}
