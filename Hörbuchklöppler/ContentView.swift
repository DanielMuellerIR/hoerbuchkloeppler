import HoerbuchkloepplerCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AppKit
import AVFoundation
import Combine

struct ContentView: View {
    @StateObject private var flow = OutputCoordinator()
    @StateObject var session = ConversionSession()
    @StateObject private var preview = ChapterPreviewPlayer()
    @State private var selectedChapters: Set<UUID> = []
    @State private var renamePrefix = "Kapitel"
    @State private var projectError: String?
    @State private var showingSettings = false
    @State private var ffmpegStatus = "Prüfe..."
    @State private var miStatus = "Prüfe..."
    @State private var showingToolErrorAlert = false
    @State private var cliHandoffError: String?
    /// Einmal aufgelöster CLI-Pfad. Die Auflösung durchsucht den gesamten PATH
    /// mit je einem Dateisystemzugriff pro Eintrag; im View-Body ausgewertet
    /// liefe das bei jedem Fortschritts-Update zweimal auf dem Main Actor und
    /// würde bei einem Netz-Mount im PATH die Oberfläche blockieren.
    @State private var kloepplerURL: URL?

    func checkTools() {
        session.logCurrentSettings()
        Task {
            let (ffmpeg, mediaInfo, kloeppler) = await Task.detached {
                FFmpegWrapper.cleanupOldTempDirectories()
                return (
                    FFmpegWrapper.toolVersion(name: "ffmpeg"),
                    FFmpegWrapper.toolVersion(name: "mediainfo"),
                    Self.resolveKloepplerURL()
                )
            }.value
            kloepplerURL = kloeppler
            if let (url, version) = ffmpeg {
                ffmpegStatus = "OK (\(version))"
                session.addLog("🛠️ FFmpeg gefunden an \(url.path) (Version: \(version))")
            } else {
                ffmpegStatus = "Nicht gefunden"
                session.addLog("❌ FFmpeg NICHT gefunden!")
            }
            if let (url, version) = mediaInfo {
                miStatus = "OK (\(version))"
                session.addLog("🛠️ MediaInfo gefunden an \(url.path) (Version: \(version))")
            } else {
                miStatus = "Nicht gefunden"
                session.addLog("❌ MediaInfo NICHT gefunden!")
            }
        }
    }

    private func saveAndExport() {
        guard ffmpegStatus.contains("OK"), miStatus.contains("OK") else { showingToolErrorAlert = true; return }
        flow.selectOutput(session: session)
    }

    var body: some View {
        ZStack {
            HSplitView {
                // --- Linke Sidebar (Cover & Metadaten) ---
                VStack(spacing: 20) {
                    VStack {
                        CoverView(image: $session.coverImage, onDropped: { url in session.selectCover(url: url) })
                            .frame(width: 180, height: 180).shadow(radius: 5)
                        if session.coverImage != nil || session.coverPath != nil {
                            Button(action: { session.removeCover() }) {
                                Label("Cover entfernen", systemImage: "trash").font(.system(size: 11)).foregroundColor(.red)
                            }.buttonStyle(.plain).padding(.top, 5)
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Group {
                            Label("Titel", systemImage: "text.alignleft")
                            TextField("Hörbuch Titel", text: $session.title).textFieldStyle(.roundedBorder)
                            Label("Autor", systemImage: "person")
                            TextField("Autor", text: $session.author).textFieldStyle(.roundedBorder)
                            Label("Genre", systemImage: "music.note")
                            TextField("Genre", text: $session.genre).textFieldStyle(.roundedBorder)
                            TextField("Sprecher", text: $session.narrator).textFieldStyle(.roundedBorder)
                            TextField("Reihe", text: $session.series).textFieldStyle(.roundedBorder)
                            TextField("Bandnummer", text: $session.volumeNumber).textFieldStyle(.roundedBorder)
                            TextField("Sprache (z. B. de)", text: $session.language).textFieldStyle(.roundedBorder)
                        }.font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    Spacer() // Drückt alles nach oben und unten
                    Button(action: { showingSettings.toggle() }) {
                        Label("Einstellungen", systemImage: "gearshape").font(.system(size: 16, weight: .medium))
                    }.buttonStyle(.bordered).padding(.bottom, 10)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("System-Check").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                        Text("FFmpeg: \(ffmpegStatus)").foregroundColor(ffmpegStatus.contains("OK") ? .secondary : .red)
                        Text("MediaInfo: \(miStatus)").foregroundColor(miStatus.contains("OK") ? .secondary : .red)
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                    .padding(.horizontal)
                }
                .frame(width: 250).padding().background(Color(NSColor.windowBackgroundColor))

                // --- Rechte Seite (Dateiliste & Progress) ---
                VStack {
                    if session.audioFiles.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "music.note").font(.largeTitle).foregroundColor(.gray)
                            Text("Audiodateien oder Ordner hierherziehen")
                                .font(.headline).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.gray.opacity(0.1)).cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3), lineWidth: 1))
                    } else {
                        VStack(spacing: 0) {
                            HStack {
                                Spacer()
                                Button("Alle löschen") {
                                    preview.stop()
                                    session.audioFiles.removeAll()
                                }
                                    .foregroundColor(.red).buttonStyle(.bordered)
                            }.padding([.top, .horizontal])
                            HStack {
                                TextField("Titelpräfix", text: $renamePrefix).frame(width: 120)
                                Button("Auswahl nummerieren") { session.renameChapters(ids: selectedChapters, prefix: renamePrefix) }
                                    .disabled(selectedChapters.isEmpty)
                                Button("↑") { moveSelection(by: -1) }.disabled(selectedChapters.count != 1)
                                Button("↓") { moveSelection(by: 1) }.disabled(selectedChapters.count != 1)
                                Button("Teilen") {
                                    if let id = preview.playingID, let time = preview.absolutePlaybackTime {
                                        preview.stop(); session.splitChapter(id: id, at: time)
                                    }
                                }.disabled(preview.playingID == nil).help("Kapitel an der aktuellen Abspielposition teilen")
                                Button("Zusammenführen") {
                                    if let id = selectedChapters.first { preview.stop(); session.mergeChapterWithNext(id: id) }
                                }.disabled(selectedChapters.count != 1).help("Mit dem unmittelbar folgenden Zeitabschnitt derselben Quelle zusammenführen")
                            }.padding(.horizontal)
                            List(selection: $selectedChapters) {
                                ForEach($session.audioFiles) { $file in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Image(systemName: "music.note").foregroundColor(.accentColor).frame(width: 20)
                                            TextField("Kapitel Titel", text: $file.chapterTitle).textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                                            Spacer()
                                            Text(formatDuration(file.duration))
                                                .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                                                .help("Kapitel-Dauer")
                                            Button(action: { preview.toggle(file) }) {
                                                Image(systemName: preview.playingID == file.id ? "pause.circle.fill" : "play.circle")
                                                    .foregroundColor(.green).frame(width: 20)
                                            }.buttonStyle(.plain).help("Kapitel anhören")
                                            Button(action: { session.fetchRawMediaInfo(for: file) }) { Image(systemName: "info.circle").foregroundColor(.blue).frame(width: 20) }.buttonStyle(.plain)
                                            Button(action: { if preview.playingID == file.id { preview.stop() }; session.audioFiles.removeAll(where: { $0.id == file.id }) }) { Image(systemName: "trash").foregroundColor(.red).frame(width: 20) }.buttonStyle(.plain)
                                        }
                                        Text(file.name).font(.system(size: 10)).foregroundColor(.gray).padding(.leading, 30)
                                    }
                                    .padding(.vertical, 4)
                                    .tag(file.id)
                                }
                                .onMove { offsets, destination in session.moveChapters(from: offsets, to: destination) }
                            }
                        }
                    }

                    VStack {
                        Spacer()
                        Button(action: saveAndExport) {
                            Text("Hörbuch erzeugen").frame(width: 200, height: 35)
                        }
                        .keyboardShortcut("r", modifiers: .command).buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(
                            session.isConverting
                                || session.isImporting
                                || session.audioFiles.isEmpty
                                || session.isPreparingArtwork
                        )
                        Spacer()
                        
                        HStack {
                            Spacer()
                            Button(action: copyAndOpenCLI) {
                                Text("-> CLI")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(4)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(
                                session.cliFolderIfRepresentable == nil
                                    || kloepplerURL == nil
                            )
                            .help(cliHandoffHelp)
                        }
                        .padding(.trailing, 20)
                        .padding(.bottom, 10)
                    }
                    .frame(height: 130)
                }
            }

            // Das Overlay bleibt bis zum definitiven Abschluss sichtbar.
            if session.showOverlay {
                ConversionOverlayView(session: session)
                    .transition(.opacity)
                    .zIndex(10)
                    .onAppear {
                        Task { @MainActor in
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        }
                    }
            }
        }
        .alert("Tools fehlen", isPresented: $showingToolErrorAlert) { Button("OK", role: .cancel) { } } message: {
            Text("Für die Konvertierung werden FFmpeg und MediaInfo benötigt.\n\nBitte installieren Sie Homebrew und führen Sie im Terminal aus:\nbrew install ffmpeg mediainfo")
        }
        .errorAlert(
            "Import nicht übernommen",
            message: $session.importErrorMessage,
            fallback: "Unbekannter Analysefehler"
        )
        .errorAlert(
            "Konvertierung nicht gestartet",
            message: $flow.conversionStartError,
            fallback: "Unbekannter Startfehler"
        )
        .errorAlert(
            "CLI-Handoff fehlgeschlagen",
            message: $cliHandoffError,
            fallback: "Das Terminal konnte nicht geöffnet werden."
        )
        .onAppear { checkTools() }
        .frame(minWidth: 850, minHeight: 650) // Fenster etwas höher gemacht (650 statt 550)
        .sheet(isPresented: $showingSettings) { SettingsView(session: session, isPresented: $showingSettings) }
        .alert("Datei existiert bereits", isPresented: $flow.showingOverwriteAlert) {
            Button("Abbrechen", role: .cancel) { }
            Button("Drüberklöppeln", role: .destructive) {
                if let plan = flow.pendingPlan { flow.start(plan, session: session) }
            }
        } message: {
            Text("Diese tatsächlichen Zieldateien existieren bereits:\n\(flow.collidingOutputNames.joined(separator: "\n"))\n\nMöchten Sie sie wirklich überklöppeln?")
        }
        .sheet(isPresented: $flow.showingConversionPreview) {
            if let plan = flow.previewPlan {
                OutputPreviewView(preview: ConversionPreview(plan: plan, settings: session.settings), onCancel: { flow.showingConversionPreview = false }, onStart: {
                    flow.showingConversionPreview = false
                    flow.confirmPreview(plan, session: session)
                })
            }
        }
        .sheet(isPresented: $session.showSelectionUI) { MetadataSelectionView(session: session) }
        .sheet(isPresented: $session.showInfoSheet) {
            VStack(spacing: 0) {
                HStack { Text("Datei-Details").font(.headline).padding(.leading); Spacer(); Button("Schließen") { session.cancelRawMediaInfo() }.padding(.trailing) }.frame(height: 40).background(Color(NSColor.windowBackgroundColor))
                Divider()
                ZStack {
                    if session.isFetchingInfo { ProgressView() } else { ScrollView { Text(session.selectedFileInfoText).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 700, height: 500)
            .onDisappear { session.cancelRawMediaInfo() }
        }
        .alert("Projekt", isPresented: Binding(get: { projectError != nil }, set: { if !$0 { projectError = nil } })) {
            Button("OK", role: .cancel) { projectError = nil }
        } message: { Text(projectError ?? "") }
        .toolbar {
            Button("Projekt öffnen …") { projectPanel(save: false) }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(session.isConverting)
            Button("Projekt speichern …") { projectPanel(save: true) }.keyboardShortcut("s", modifiers: .command).disabled(session.isConverting || session.isImporting)
            Button("Rückgängig") { preview.stop(); session.undoChapterEdit() }.keyboardShortcut("z", modifiers: .command).disabled(!session.canUndoChapters || session.isConverting)
            Button("Wiederholen") { preview.stop(); session.redoChapterEdit() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!session.canRedoChapters || session.isConverting)
            Button("Dateien oder Ordner hinzufügen …", action: chooseImportSources)
                .keyboardShortcut("o", modifiers: .command)
                .disabled(session.isConverting)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading) {
                ForEach(session.projectSourceIssues) { issue in Text("\(issue.reason): \(issue.path)").foregroundColor(.red).textSelection(.enabled) }
            }
            if session.isImporting {
                HStack {
                    ProgressView(value: Double(session.importCompletedItems), total: Double(max(1, session.importTotalItems)))
                        .frame(width: 140)
                    Text("\(session.importCompletedItems) / \(session.importTotalItems): \(session.importDetail)")
                        .lineLimit(1)
                    Spacer()
                    Button("Import abbrechen") { session.cancelImport() }
                        .disabled(!session.canCancelImport)
                }.padding(8)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !session.isConverting else { return false }
            ImportCoordinator.importProviders(providers, session: session)
            return true
        }
    }

    private func moveSelection(by offset: Int) {
        guard let id = selectedChapters.first, let index = session.audioFiles.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard session.audioFiles.indices.contains(target) else { return }
        session.moveChapters(from: IndexSet(integer: index), to: offset > 0 ? target + 1 : target)
    }

    private func projectPanel(save: Bool) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        if save {
            let panel = NSSavePanel(); panel.nameFieldStringValue = "Hörbuch.hkproject"
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                Task { do { try await session.saveProjectAsync(to: url) } catch { projectError = error.localizedDescription } }
            }
        } else {
            let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                Task { do { preview.stop(); try await session.openProjectAsync(from: url) } catch { projectError = error.localizedDescription } }
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
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                await ImportCoordinator.importURLs(urls, session: session)
            }
        }
    }

    /// Kapitel-Dauer als `m:ss` bzw. `h:mm:ss` (ab einer Stunde).
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func copyAndOpenCLI() {
        guard let folderURL = session.cliFolderIfRepresentable else {
            session.addLog("⚠️ CLI-Übergabe nicht möglich: Die aktuelle Liste stammt nicht vollständig aus einem einzelnen Ordner-Import.")
            return
        }
        // Beim Klick erneut auflösen: Der beim Start gemerkte Pfad kann
        // inzwischen verschwunden sein, und ein einzelner Klick trägt die
        // Suchkosten problemlos.
        guard let kloepplerURL = Self.resolveKloepplerURL() else {
            self.kloepplerURL = nil
            session.addLog("⚠️ CLI-Übergabe nicht möglich: Das Programm „kloeppler“ wurde nicht gefunden.")
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
            session.addLog("⚠️ \(message)")
            cliHandoffError = message
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
        if session.cliFolderIfRepresentable == nil {
            return "Nur verfügbar, wenn die aktuelle Liste vollständig aus einem einzelnen Ordner-Import stammt."
        }
        if kloepplerURL == nil {
            return "Nicht verfügbar, weil das Programm „kloeppler“ nicht gefunden wurde."
        }
        return "Öffnet das Terminal mit dem vollständigen Befehl für die aktuellen Einstellungen, Metadaten und das Cover."
    }
}

struct CoverView: View {
    @Binding var image: NSImage?
    /// Übernimmt eine gedroppte Bilddatei. Läuft über `session.selectCover(url:)`,
    /// damit das Bild auf max. 2000 px skaliert und ein zuvor gefundenes
    /// eingebettetes Cover (`embeddedCoverData`) verworfen wird — sonst gewänne
    /// beim Kodieren das alte eingebettete Artwork statt des gedroppten Bilds.
    var onDropped: (URL) -> Void
    var body: some View {
        ZStack {
            if let img = image { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
            else { Color.gray.opacity(0.2); VStack { Image(systemName: "photo.on.rectangle.angled").font(.largeTitle).foregroundColor(.gray); Text("Cover Drop").font(.caption).foregroundColor(.gray) } }
        }
        .frame(width: 180, height: 180).cornerRadius(12).clipped()
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            if let provider = providers.first {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    Task { @MainActor in
                        if let url { self.onDropped(url) }
                    }
                }
            }
            return true
        }
    }
}
