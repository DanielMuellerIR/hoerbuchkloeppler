import Foundation
import Combine
import HoerbuchkloepplerCore
import UniformTypeIdentifiers
import AppKit

@MainActor
public final class DocumentOpenDelegate: NSObject, NSApplicationDelegate {
    public func application(_ application: NSApplication, open urls: [URL]) {
        DocumentOpenCoordinator.receiveSystemURLs(urls)
    }
}

@MainActor
public final class DocumentOpenCoordinator: ObservableObject {
    private struct OpeningContext {
        let generation: UUID
        let session: ConversionSession
        let beforeOpening: @MainActor () -> Void
    }

    public static let projectType = UTType(exportedAs: "danielmueller.Hoerbuchkloeppler.project", conformingTo: .json)
    public static let windowID = "audiobook"
    public static var createWindow: (() -> Void)?
    private static let receivers = NSMapTable<NSWindow, DocumentOpenCoordinator>.weakToWeakObjects()
    private static var unroutedURLs: [URL] = []
    private static var requestingWindow = false

    @Published public var projectToConfirm: URL?
    @Published public var errorMessage: String?
    private var pendingURLs: [URL] = []
    private var collectionTask: Task<Void, Never>?
    private var classificationTask: Task<Bool, Never>?
    private var isOpening = false
    private var ownerGeneration = UUID()
    private var wasAttached = false
    public private(set) weak var window: NSWindow?
    private weak var boundSession: ConversionSession?
    private var beforeSystemOpening: (@MainActor () -> Void)?
    private var windowCloseSubscription: AnyCancellable?
    private let classifyAudio: @MainActor ([URL]) async -> Bool
    private let importAudio: @MainActor ([URL], ConversionSession) async -> Void

    public convenience init(importAudio: @escaping @MainActor ([URL], ConversionSession) async -> Void = { urls, session in
        await ImportCoordinator.importURLs(urls, session: session)
    }) {
        self.init(classifyAudio: ConversionSession.areReadableAudioFiles, importAudio: importAudio)
    }

    init(classifyAudio: @escaping @MainActor ([URL]) async -> Bool,
         importAudio: @escaping @MainActor ([URL], ConversionSession) async -> Void) {
        self.classifyAudio = classifyAudio
        self.importAudio = importAudio
    }

    public func attach(to window: NSWindow?, session: ConversionSession, beforeOpening: @escaping @MainActor () -> Void) {
        if let window, self.window === window, boundSession === session {
            beforeSystemOpening = beforeOpening
            Self.routeSystemURLs()
            return
        }
        detach()
        guard let window else { return }
        if let previous = Self.receivers.object(forKey: window), previous !== self {
            previous.detach()
        }
        wasAttached = true
        self.window = window
        boundSession = session
        beforeSystemOpening = beforeOpening
        Self.receivers.setObject(self, forKey: window)
        let generation = ownerGeneration
        windowCloseSubscription = NotificationCenter.default.publisher(
            for: NSWindow.willCloseNotification, object: window
        ).sink { [weak self] _ in
            guard let self, self.ownerGeneration == generation else { return }
            self.detach()
        }
        Self.requestingWindow = false
        Self.routeSystemURLs()
    }

    private func detach() {
        windowCloseSubscription = nil
        if let window, Self.receivers.object(forKey: window) === self {
            Self.receivers.removeObject(forKey: window)
        }
        window = nil
        boundSession = nil
        beforeSystemOpening = nil
        ownerGeneration = UUID()
        isOpening = false
        pendingURLs.removeAll()
        collectionTask?.cancel()
        collectionTask = nil
        classificationTask?.cancel()
        classificationTask = nil
        if projectToConfirm != nil { projectToConfirm = nil }
        if errorMessage != nil { errorMessage = nil }
    }

    private func owns(_ context: OpeningContext) -> Bool {
        guard ownerGeneration == context.generation else { return false }
        if !wasAttached { return true }
        guard let window, boundSession === context.session else { return false }
        return Self.receivers.object(forKey: window) === self
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

    public func receive(_ url: URL, session: ConversionSession, beforeOpening: @escaping @MainActor () -> Void) {
        let context = OpeningContext(generation: ownerGeneration, session: session, beforeOpening: beforeOpening)
        guard owns(context) else { return }
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
            guard let self, !Task.isCancelled, self.owns(context) else { return }
            self.collectionTask = nil
            await self.drainPending(context)
        }
    }

    public func confirmProject(_ url: URL, session: ConversionSession, beforeOpening: @escaping @MainActor () -> Void) async {
        let context = OpeningContext(generation: ownerGeneration, session: session, beforeOpening: beforeOpening)
        guard owns(context), !isOpening else { return }
        projectToConfirm = nil
        isOpening = true
        await openProject(url, context: context)
        guard owns(context) else { return }
        isOpening = false
        await drainPending(context)
    }

    public func cancelProject() { projectToConfirm = nil }

    private func drainPending(_ context: OpeningContext) async {
        guard owns(context), !isOpening else { return }
        isOpening = true
        defer { if owns(context) { isOpening = false } }
        // Spätere URLs werden gesammelt, während ein begonnener Import läuft.
        // Er darf für die bisherige Session fertig werden, ohne neue URLs eines
        // inzwischen übernommenen Fensters zu verbrauchen.
        while owns(context), !pendingURLs.isEmpty, projectToConfirm == nil {
            let urls = pendingURLs
            pendingURLs = []
            await open(urls, context: context)
        }
    }

    private func open(_ urls: [URL], context: OpeningContext) async {
        let session = context.session
        guard owns(context), canOpen(session) else { return }
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
                await openProject(projects[0], context: context)
            }
            return
        }
        let classification = Task { [classifyAudio] in await classifyAudio(urls) }
        classificationTask = classification
        let readable = await classification.value
        guard owns(context) else { return }
        classificationTask = nil
        guard readable else {
            errorMessage = "Die Auswahl enthält keine unterstützte, lesbare Audiodatei."
            return
        }
        guard canOpen(session) else { return }
        context.beforeOpening()
        guard owns(context) else { return }
        await importAudio(urls, session)
    }

    private func openProject(_ url: URL, context: OpeningContext) async {
        guard owns(context), canOpen(context.session) else { return }
        context.beforeOpening()
        guard owns(context) else { return }
        do { try await context.session.openProjectAsync(from: url) }
        catch { if owns(context) { errorMessage = error.localizedDescription } }
    }

    private func canOpen(_ session: ConversionSession) -> Bool {
        guard !session.isConverting, !session.isImporting else {
            errorMessage = "Es läuft bereits ein Import oder eine Konvertierung. Bitte danach erneut öffnen."
            return false
        }
        return true
    }

    deinit {
        collectionTask?.cancel()
        classificationTask?.cancel()
    }
}
