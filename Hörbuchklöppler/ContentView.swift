import HoerbuchkloepplerAppSupport
import HoerbuchkloepplerCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @StateObject private var flow = OutputCoordinator()
    @StateObject var session = ConversionSession()
    @StateObject private var preview = ChapterPreviewPlayer()
    @StateObject private var undoRouter = ChapterUndoRouter()
    @StateObject private var documentOpen = DocumentOpenCoordinator()
    @StateObject private var coverDrop = CoverDropCoordinator()
    @Environment(\.openWindow) private var openWindow
    @StateObject private var presentation = WindowPresentationCoordinator()
    @State private var toolStatus = ToolStatus()
    /// Einmal aufgelöster CLI-Pfad. Die Auflösung durchsucht den gesamten PATH
    /// mit je einem Dateisystemzugriff pro Eintrag; im View-Body ausgewertet
    /// liefe das bei jedem Fortschritts-Update zweimal auf dem Main Actor und
    /// würde bei einem Netz-Mount im PATH die Oberfläche blockieren.
    @State private var kloepplerURL: URL?

    private func checkTools() async {
        toolStatus = ToolStatus()
        session.logCurrentSettings()
        let (ffmpeg, mediaInfo, kloeppler) = await Task.detached {
            FFmpegWrapper.cleanupOldTempDirectories()
            return (
                FFmpegWrapper.toolVersion(name: "ffmpeg"),
                FFmpegWrapper.toolVersion(name: "mediainfo"),
                Self.resolveKloepplerURL()
            )
        }.value
        guard !Task.isCancelled else { return }
        kloepplerURL = kloeppler
        toolStatus = ToolStatus(
            ffmpeg: reportTool("FFmpeg", result: ffmpeg),
            mediaInfo: reportTool("MediaInfo", result: mediaInfo)
        )
    }

    private func reportTool(_ name: String, result: (url: URL, version: String)?) -> ToolStatus.Availability {
        if let (url, version) = result {
            session.addLog("\(name) gefunden an \(url.path) (Version: \(version))")
            return .available(version: version)
        }
        session.addLog("\(name) nicht verfügbar.")
        return .unavailable
    }

    private func saveAndExport() {
        guard canExport else { return }
        switch toolStatus.exportAvailability {
        case .checking: return
        case .available: flow.selectOutput(session: session, coverDrop: coverDrop, presentation: presentation)
        case .unavailable(let message): presentation.present(.error(title: "Werkzeuge nicht verfügbar", message: message))
        }
    }


    var body: some View {
        ZStack {
            HSplitView {
                SidebarMetadataView(session: session, toolStatus: toolStatus, onFileDrop: { provider in
                    coverDrop.load(provider, session: session)
                }, showSettings: { presentation.request(.settings) })

                VStack {
                    ChapterListView(session: session, preview: preview)
                    ExportFooterView(
                        busyMessage: flow.activity?.rawValue ?? (coverDrop.isPending ? "Cover wird geladen …" : nil),
                        canExport: canExport,
                        canOpenCLI: !coverDrop.isPending && session.cliFolderIfRepresentable != nil && kloepplerURL != nil,
                        cliHelp: cliHandoffHelp,
                        export: saveAndExport,
                        cancelWork: {
                            if flow.activity != nil { flow.cancelWork() }
                            else { coverDrop.cancel() }
                        },
                        openCLI: copyAndOpenCLI
                    )
                }
            }

            if session.showOverlay {
                ConversionOverlayView(session: session)
                    .transition(.opacity)
                    .zIndex(10)
                    .onAppear {
                        Task { @MainActor in documentOpen.window?.makeFirstResponder(nil) }
                    }
            }
        }
        .background { sheetHost }
        .task { await checkTools() }
        .onChange(of: modelErrors.map { $0.message.wrappedValue }) { _ in receiveModelErrors() }
        .onChange(of: session.showSelectionUI) { updateSheet(.metadata, requested: $0) }
        .onChange(of: session.showInfoSheet) { updateSheet(.fileInfo, requested: $0) }
        .onChange(of: documentOpen.projectToConfirm) { url in
            if let url { confirmProjectOpen(url) }
        }
        .onDisappear {
            presentation.detach()
            coverDrop.cancel()
            flow.cancelWork()
        }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .frame(minWidth: 850, minHeight: 650)
        .toolbar {
            Button("Projekt öffnen …") { projectPanel(save: false) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(session.isConverting)
            Button("Projekt speichern …") { projectPanel(save: true) }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(session.isConverting || session.isImporting)
            Button("Rückgängig") { undoRouter.undo() }.disabled(!undoRouter.canUndo)
            Button("Wiederholen") { undoRouter.redo() }.disabled(!undoRouter.canRedo)
            Button("Dateien oder Ordner hinzufügen …", action: chooseImportSources)
                .keyboardShortcut("o", modifiers: .command)
                .disabled(session.isConverting)
        }
        .safeAreaInset(edge: .bottom) { importStatus }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !session.isConverting else { return false }
            importProviders(providers)
            return true
        }
        .background(ProjectWindowReader(router: undoRouter) { [weak documentOpen, weak session, weak preview, weak presentation, weak flow, weak coverDrop] window in
            presentation?.attach(to: window) { [weak documentOpen, weak flow, weak coverDrop] in
                documentOpen?.cancelProject()
                flow?.cancelWork()
                coverDrop?.cancel()
            }
            guard let documentOpen, let session else { return }
            documentOpen.attach(to: window, session: session, beforeOpening: { [weak preview] in preview?.stop() })
        })
        .focusedSceneObject(undoRouter)
        .onAppear {
            receiveModelErrors()
            updateSheet(.metadata, requested: session.showSelectionUI)
            updateSheet(.fileInfo, requested: session.showInfoSheet)
            undoRouter.configure(session: session, beforeChapterEdit: { preview.stop() })
            let action = openWindow
            DocumentOpenCoordinator.createWindow = { action(id: DocumentOpenCoordinator.windowID) }
        }
    }

    private var canExport: Bool {
        !session.isConverting && !session.isImporting && !session.audioFiles.isEmpty
            && !session.isPreparingArtwork && !coverDrop.isPending
            && flow.activity == nil && flow.preview == nil && toolStatus.exportAvailability != .checking
    }

    private func fileInfoSheet(_ sheet: PresentedWindowSheet) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Datei-Details").font(.headline)
                Spacer()
                Button("Schließen") { presentation.dismissSheet(sheet.id) }
            }
            .padding(.horizontal)
            .frame(height: 40)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            ZStack {
                if session.isFetchingInfo {
                    ProgressView()
                } else {
                    ScrollView {
                        Text(session.selectedFileInfoText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 700, height: 500)
    }

    private var importStatus: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading) {
                ForEach(session.projectSourceIssues) { issue in
                    Text("\(issue.reason): \(issue.path)").foregroundStyle(.red).textSelection(.enabled)
                }
            }
            if session.isImporting {
                HStack {
                    ProgressView(value: Double(session.importCompletedItems), total: Double(max(1, session.importTotalItems)))
                        .frame(width: 140)
                    Text("\(session.importCompletedItems) / \(session.importTotalItems): \(session.importDetail)")
                        .lineLimit(1)
                    Spacer()
                    Button("Import abbrechen", action: session.cancelImport)
                        .disabled(!session.canCancelImport)
                }
                .padding(8)
            }
        }
    }

    private var modelErrors: [(title: String, message: Binding<String?>)] {
        [
            ("Import nicht übernommen", $session.importErrorMessage),
            ("Konvertierung nicht gestartet", $flow.conversionStartError),
            ("Cover nicht übernommen", $coverDrop.errorMessage),
            ("Vorschau nicht möglich", $preview.unplayableFile),
            ("Datei nicht geöffnet", $documentOpen.errorMessage)
        ]
    }

    private func receiveModelErrors() {
        for source in modelErrors {
            guard let message = source.message.wrappedValue else { continue }
            source.message.wrappedValue = nil
            presentation.present(.error(title: source.title, message: message))
        }
    }

    @ViewBuilder
    private var sheetHost: some View {
        if let sheet = presentation.sheet {
            Color.clear.frame(width: 0, height: 0)
                .sheet(isPresented: sheetBinding(sheet), onDismiss: {
                    presentation.sheetDismissed(sheet.id)
                }) {
                    sheetContent(sheet)
                        .onAppear { presentation.sheetAppeared(sheet.id) }
                }
                // Der Callback gehört zum Host dieses Tickets, auch nach Fensterwechsel.
                .id(sheet.id)
        }
    }

    private func sheetBinding(_ sheet: PresentedWindowSheet) -> Binding<Bool> {
        Binding(get: {
            presentation.sheet?.id == sheet.id && presentation.sheet?.isPresented == true
        }, set: { presented in
            if !presented { presentation.dismissSheet(sheet.id) }
        })
    }

    @ViewBuilder
    private func sheetContent(_ sheet: PresentedWindowSheet) -> some View {
        switch sheet.kind {
        case .settings:
            SettingsView(session: session, isPresented: sheetBinding(sheet))
        case .conversionPreview:
            if let preview = flow.preview {
                OutputPreviewView(preview: preview, onCancel: {
                    presentation.dismissSheet(sheet.id)
                }, onStart: {
                    flow.confirmPreview(sheet.id, session: session, coverDrop: coverDrop, presentation: presentation)
                    presentation.dismissSheet(sheet.id)
                })
            }
        case .metadata: MetadataSelectionView(session: session)
        case .fileInfo: fileInfoSheet(sheet)
        }
    }

    private func updateSheet(_ kind: WindowSheet, requested: Bool) {
        guard requested else {
            presentation.dismiss(kind)
            return
        }
        presentation.request(kind) { _ in
            guard !presentation.isQueued(kind) else { return }
            switch kind {
            case .metadata: session.showSelectionUI = false
            case .fileInfo: session.cancelRawMediaInfo()
            case .settings, .conversionPreview: break
            }
        }
    }

    private func confirmProjectOpen(_ url: URL) {
        presentation.present(.openProject(url)) { accepted in
            guard documentOpen.projectToConfirm == url else { return }
            guard accepted else {
                documentOpen.cancelProject()
                return
            }
            Task { [weak owner = documentOpen.window] in
                guard let owner, documentOpen.window === owner, documentOpen.projectToConfirm == url else { return }
                await documentOpen.confirmProject(url, session: session, beforeOpening: { preview.stop() })
            }
        }
    }

    private func confirmImportRetry(_ providers: [NSItemProvider]) {
        presentation.present(.retryImport) { accepted in
            guard accepted else { return }
            guard !session.isConverting, !session.isImporting else {
                presentation.present(.error(
                    title: "Import nicht gestartet",
                    message: "Es läuft bereits ein Import oder eine Konvertierung. Bitte danach erneut importieren."
                ))
                return
            }
            importProviders(providers)
        }
    }

    private func showCLIError(_ message: String) {
        presentation.present(.error(title: "CLI-Handoff fehlgeschlagen", message: message))
    }

    private func projectPanel(save: Bool) {
        if save {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Hörbuch.hkproject"
            panel.allowedContentTypes = [DocumentOpenCoordinator.projectType]
            presentation.present(panel) { response in
                guard response == .OK, let url = panel.url else { return }
                Task {
                    do { try await session.saveProjectAsync(to: url) }
                    catch { presentation.present(.error(title: "Projekt nicht gespeichert", message: error.localizedDescription)) }
                }
            }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [DocumentOpenCoordinator.projectType]
            presentation.present(panel) { response in
                guard response == .OK, let url = panel.url else { return }
                documentOpen.receive(url, session: session, beforeOpening: { preview.stop() })
            }
        }
    }

    private func chooseImportSources() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Importieren"
        panel.message = "Audiodateien oder Ordner auswählen"
        presentation.present(panel) { response in
            // Eine bestätigte Auswahl ohne Dateien darf keinen leeren Batch
            // starten: Der entwertete dann die laufende Cover-Suche.
            guard response == .OK, !panel.urls.isEmpty else { return }
            let urls = panel.urls
            Task { @MainActor in
                await ImportCoordinator.importURLs(urls, session: session)
            }
        }
    }

    private func importProviders(_ providers: [NSItemProvider]) {
        ImportCoordinator.importProviders(providers, session: session, onTimeout: { providers in
            confirmImportRetry(providers)
        })
    }

    private func copyAndOpenCLI() {
        guard !coverDrop.isPending else { return }
        // Über `addLog` allein wäre die Meldung unsichtbar: Das Protokoll zeigt
        // nur das Konvertierungs-Overlay, und das ist beim CLI-Handoff nie offen.
        guard let folderURL = session.cliFolderIfRepresentable else {
            showCLIError("Die aktuelle Liste stammt nicht vollständig aus einem einzelnen Ordner-Import.")
            return
        }
        // Beim Klick erneut auflösen: Der beim Start gemerkte Pfad kann
        // inzwischen verschwunden sein, und ein einzelner Klick trägt die
        // Suchkosten problemlos.
        guard let kloepplerURL = Self.resolveKloepplerURL() else {
            self.kloepplerURL = nil
            showCLIError("Das Programm „kloeppler“ wurde nicht gefunden.")
            return
        }
        self.kloepplerURL = kloepplerURL

        let invocation = CLIInvocation(
            executable: kloepplerURL.path,
            folderURL: folderURL,
            settings: session.settings,
            title: session.title,
            author: session.author,
            genre: session.genre,
            coverPath: session.coverPath,
            suppressCover: session.isCoverSuppressed,
            narrator: session.narrator, series: session.series, volumeNumber: session.volumeNumber, language: session.language
        )

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(invocation.shellCommand, forType: .string)

        let terminalDirectory = kloepplerURL.deletingLastPathComponent()
        Task {
            guard let message = await Self.openTerminal(at: terminalDirectory) else { return }
            session.addLog(message, type: .warning)
            showCLIError(message)
        }
    }

    /// `Process.run()` bestätigt nur den Start von `/usr/bin/open`. Dessen
    /// eigentlicher Fehler kommt als späterer Exit-Code und wird deshalb auf
    /// einem Hintergrund-Task bis zum Prozessende ausgewertet.
    private static func openTerminal(at directory: URL) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Terminal", directory.path]
            do {
                try process.run()
            } catch {
                return "Terminal konnte nicht geöffnet werden: \(error.localizedDescription)"
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return "Terminal konnte nicht geöffnet werden (Exit-Code \(process.terminationStatus))."
            }
            return nil
        }.value
    }

    /// `nonisolated`, damit der PATH-Scan im Hintergrund-Task laufen darf
    /// statt den Main Actor zu blockieren.
    private nonisolated static func resolveKloepplerURL() -> URL? {
        // In Entwicklungs-Builds liegt die CLI neben der App oder im
        // SwiftPM-Release-Verzeichnis. Installierte Builds bieten den Handoff nur
        // an, wenn eine ausführbare CLI im PATH/üblichen Installationsort liegt.
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let candidates = [
            appDir.appendingPathComponent("kloeppler"),
            appDir.appendingPathComponent("HoerbuchkloepplerCore/.build/release/kloeppler")
        ]
        return candidates.first(where: FFmpegWrapper.isUsableExecutable)
            ?? FFmpegWrapper.getBinaryURL(name: "kloeppler")
    }

    private var cliHandoffHelp: String {
        if coverDrop.isPending { return "Cover wird geladen …" }
        if session.cliFolderIfRepresentable == nil {
            return "Nur verfügbar, wenn die aktuelle Liste vollständig aus einem einzelnen Ordner-Import stammt."
        }
        if kloepplerURL == nil {
            return "Nicht verfügbar, weil das Programm „kloeppler“ nicht gefunden wurde."
        }
        return "Öffnet das Terminal mit dem vollständigen Befehl für die aktuellen Einstellungen, Metadaten und das Cover."
    }
}
