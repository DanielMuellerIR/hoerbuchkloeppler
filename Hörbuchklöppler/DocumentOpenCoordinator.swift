import Foundation
import Combine
import HoerbuchkloepplerCore
import UniformTypeIdentifiers
import AppKit

@MainActor
final class DocumentOpenDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        DocumentOpenCoordinator.receiveSystemURLs(urls)
    }
}

@MainActor
final class DocumentOpenCoordinator: ObservableObject {
    static let projectType = UTType(exportedAs: "danielmueller.Hoerbuchkloeppler.project", conformingTo: .json)
    static let windowID = "audiobook"
    static var createWindow: (() -> Void)?
    private static let receivers = NSMapTable<NSWindow, DocumentOpenCoordinator>.weakToWeakObjects()
    private static var unroutedURLs: [URL] = []
    private static var requestingWindow = false

    @Published var projectToConfirm: URL?
    @Published var errorMessage: String?
    private var pendingURLs: [URL] = []
    private var collectionTask: Task<Void, Never>?
    private var isOpening = false
    private weak var window: NSWindow?
    private weak var boundSession: ConversionSession?
    private var beforeSystemOpening: (@MainActor () -> Void)?
    private var windowCloseSubscription: AnyCancellable?
    private let importAudio: @MainActor ([URL], ConversionSession) async -> Void

    init(importAudio: @escaping @MainActor ([URL], ConversionSession) async -> Void = { urls, session in
        await ImportCoordinator.importURLs(urls, session: session)
    }) {
        self.importAudio = importAudio
    }

    func attach(to window: NSWindow?, session: ConversionSession, beforeOpening: @escaping @MainActor () -> Void) {
        windowCloseSubscription = nil
        if let previous = self.window { Self.receivers.removeObject(forKey: previous) }
        self.window = window
        boundSession = session
        beforeSystemOpening = beforeOpening
        if let window {
            Self.receivers.setObject(self, forKey: window)
            windowCloseSubscription = NotificationCenter.default.publisher(
                for: NSWindow.willCloseNotification, object: window
            ).sink { [weak self, weak window] _ in
                guard let self, let window, self.window === window else { return }
                Self.receivers.removeObject(forKey: window)
                self.window = nil
                self.windowCloseSubscription = nil
            }
            Self.requestingWindow = false
            Self.routeSystemURLs()
        }
    }

    // AppKit liefert die vollständige Dateiliste eines Öffnungsereignisses.
    // SwiftUIs einzelner onOpenURL-Callback verlor hier weitere Dateien.
    static func receiveSystemURLs(_ urls: [URL]) {
        unroutedURLs.append(contentsOf: urls)
        routeSystemURLs()
    }

    private static func routeSystemURLs() {
        guard !unroutedURLs.isEmpty else { return }
        let keyWindow = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow
        let candidates = [keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows + NSApp.windows
        let receiver = candidates.compactMap { receivers.object(forKey: $0) }.first
        guard let receiver, let session = receiver.boundSession,
              let beforeOpening = receiver.beforeSystemOpening else {
            if !requestingWindow, !NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible }),
               let createWindow {
                requestingWindow = true
                createWindow()
            }
            return
        }
        let urls = unroutedURLs
        unroutedURLs = []
        for url in urls { receiver.receive(url, session: session, beforeOpening: beforeOpening) }
    }

    func receive(_ url: URL, session: ConversionSession, beforeOpening: @escaping @MainActor () -> Void) {
        guard url.isFileURL else {
            errorMessage = "Es können nur lokale Projekt- und Audiodateien geöffnet werden."
            return
        }
        guard projectToConfirm == nil else {
            errorMessage = "Bitte zuerst das Öffnen des ausgewählten Projekts bestätigen oder abbrechen."
            return
        }
        pendingURLs.append(url)
        guard !isOpening else { return }
        collectionTask?.cancel()
        // Auch getrennte, kurz aufeinanderfolgende Öffnungsereignisse werden
        // gebündelt, damit sie keinen gegenseitigen Importabbruch auslösen.
        collectionTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
            guard let self else { return }
            self.collectionTask = nil
            await self.drainPending(session: session, beforeOpening: beforeOpening)
        }
    }

    func confirmProject(_ url: URL, session: ConversionSession, beforeOpening: @escaping @MainActor () -> Void) async {
        projectToConfirm = nil
        guard !isOpening else { return }
        isOpening = true
        await openProject(url, session: session, beforeOpening: beforeOpening)
        isOpening = false
        await drainPending(session: session, beforeOpening: beforeOpening)
    }

    func cancelProject() { projectToConfirm = nil }

    private func drainPending(session: ConversionSession, beforeOpening: @escaping @MainActor () -> Void) async {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        // Die Sammelfrist ist nur eine Bündelung. Später zugestellte URLs
        // bleiben während unseres eigenen Imports bis zu dessen Ende erhalten.
        while !pendingURLs.isEmpty, projectToConfirm == nil {
            let urls = pendingURLs
            pendingURLs = []
            await open(urls, session: session, beforeOpening: beforeOpening)
        }
    }

    private func open(_ urls: [URL], session: ConversionSession, beforeOpening: @MainActor () -> Void) async {
        guard canOpen(session) else { return }
        let projects = urls.filter { $0.pathExtension.lowercased() == "hkproject" }
        if !projects.isEmpty {
            guard urls.count == 1 else {
                errorMessage = "Bitte ein Projekt einzeln öffnen. Audiodateien können gemeinsam importiert werden."
                return
            }
            if !session.audioFiles.isEmpty || session.bookMetadata != BookMetadata()
                || session.coverImage != nil || session.coverPath != nil {
                projectToConfirm = projects[0]
            } else {
                await openProject(projects[0], session: session, beforeOpening: beforeOpening)
            }
            return
        }
        guard urls.allSatisfy({ ConversionSession.foundFile(at: $0)?.kind == .audio }) else {
            errorMessage = "Die Auswahl enthält keine unterstützte, lesbare Audiodatei."
            return
        }
        beforeOpening()
        await importAudio(urls, session)
    }

    private func openProject(_ url: URL, session: ConversionSession, beforeOpening: @MainActor () -> Void) async {
        guard canOpen(session) else { return }
        beforeOpening()
        do { try await session.openProjectAsync(from: url) }
        catch { errorMessage = error.localizedDescription }
    }

    private func canOpen(_ session: ConversionSession) -> Bool {
        guard !session.isConverting, !session.isImporting else {
            errorMessage = "Es läuft bereits ein Import oder eine Konvertierung. Bitte danach erneut öffnen."
            return false
        }
        return true
    }

    deinit { collectionTask?.cancel() }
}
