import Foundation
import AppKit
import HoerbuchkloepplerCore

/// Provider erst sammeln: Anzahl gleichzeitiger Audioanalysen bleibt auch bei
/// großen Datei-Drops durch den gemeinsamen Importdienst begrenzt.
@MainActor
enum ImportCoordinator {
    @MainActor private final class ProviderCollection {
        var urls: [URL?]
        var remaining: Int
        init(count: Int) { urls = Array(repeating: nil, count: count); remaining = count }
    }
    static func importProviders(_ providers: [NSItemProvider], session: ConversionSession) {
        guard !providers.isEmpty else { return }
        let providerCount = providers.count
        let token = session.beginImport(expectedItemCount: providerCount)
        let collection = ProviderCollection(count: providerCount)
        for (index, provider) in providers.enumerated() {
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                let message = error?.localizedDescription
                Task { @MainActor in
                    if let url, message == nil { collection.urls[index] = url }
                    else {
                        session.stageProviderLoadFailure(position: index + 1, total: providerCount, errorDescription: message, importToken: token)
                        await session.finishImport(token)
                    }
                    collection.remaining -= 1
                    if collection.remaining == 0 {
                        let collected = collection.urls.compactMap { $0 }
                        await session.runImportTask(token) { await processURLs(collected, session: session, token: token) }
                    }
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
