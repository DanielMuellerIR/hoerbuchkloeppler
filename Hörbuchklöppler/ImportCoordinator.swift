import Foundation
import AppKit
import HoerbuchkloepplerCore

/// Führt GUI-Eingaben über denselben atomaren Core-Batch zusammen.
@MainActor
enum ImportCoordinator {
    static func importProviders(_ providers: [NSItemProvider], session: ConversionSession) {
        let importToken = session.beginImport(expectedItemCount: providers.count)
        let currentSession = session
        let providerCount = providers.count
        for (index, provider) in providers.enumerated() {
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                let errorDescription = error?.localizedDescription
                let providerFailed = error != nil || url == nil
                Task { @MainActor in
                    guard !providerFailed, let url else {
                        currentSession.stageProviderLoadFailure(
                            position: index + 1,
                            total: providerCount,
                            errorDescription: errorDescription,
                            importToken: importToken
                        )
                        await currentSession.finishImport(importToken)
                        return
                    }
                    await currentSession.runImportTask(importToken) {
                        await Self.processURL(
                            url,
                            session: currentSession,
                            importToken: importToken
                        )
                    }
                }
            }
        }
    }

    @MainActor
    static func processURL(
        _ url: URL,
        session: ConversionSession,
        importToken: ImportToken
    ) async {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let scanned = await session.scanFolder(url, importToken: importToken)
            session.stageScannedFolder(scanned, importToken: importToken)
            await session.finishImport(importToken)
        } else {
            await processSingleFile(url, session: session, importToken: importToken)
        }
    }

    @MainActor
    private static func processSingleFile(
        _ url: URL,
        session: ConversionSession,
        importToken: ImportToken
    ) async {
        if let found = ConversionSession.foundFile(at: url) {
            let loaded = await session.loadAudioFiles(from: found, importToken: importToken)
            session.stageAudioLoadResult(loaded, importToken: importToken)
        }
        await session.finishImport(importToken)
    }

}
