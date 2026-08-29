import HoerbuchkloepplerCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AppKit
import AVFoundation
import Combine

/// Spielt zum Reinhören genau EINEN Kapitel-Abschnitt einer Datei ab.
/// Funktioniert einheitlich für Einzeldateien (startTime 0, ganze Datei) und für
/// interne m4b-Kapitel (Abschnitt [startTime, startTime+duration] der großen Datei).
/// Es läuft immer nur ein Preview gleichzeitig.
@MainActor
final class ChapterPreviewPlayer: ObservableObject {
    @Published var playingID: AudioFile.ID?
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    /// Startet den Abschnitt, oder stoppt ihn, wenn dieses Kapitel gerade läuft.
    func toggle(_ file: AudioFile) {
        if playingID == file.id { stop(); return }
        stop()
        guard file.duration > 0 else { return }
        let item = AVPlayerItem(url: file.url)
        // Nur bis zum Kapitel-Ende spielen (absolute Zeit in der Item-Zeitachse).
        item.forwardPlaybackEndTime = CMTime(seconds: file.startTime + file.duration, preferredTimescale: 600)
        let p = AVPlayer(playerItem: item)
        // Am Kapitel-Ende Icon/Status zurücksetzen.
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        player = p
        playingID = file.id
        Task {
            await p.seek(to: CMTime(seconds: file.startTime, preferredTimescale: 600))
            guard player === p else { return }
            p.play()
        }
    }

    func stop() {
        player?.pause()
        player = nil
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs); endObserver = nil }
        if playingID != nil { playingID = nil }
    }
}

struct ContentView: View {
    @State private var showingOverwriteAlert = false
    @State private var pendingPlan: ConversionPlan? = nil
    @State private var collidingOutputNames: [String] = []
    @StateObject var session = ConversionSession()
    @StateObject private var preview = ChapterPreviewPlayer()
    @State private var showingSettings = false
    @State private var ffmpegStatus = "Prüfe..."
    @State private var miStatus = "Prüfe..."
    @State private var showingToolErrorAlert = false
    @State private var conversionStartError: String?
    @State private var cliHandoffError: String?

    func checkTools() {
        session.logCurrentSettings()
        Task {
            let (ffmpeg, mediaInfo) = await Task.detached {
                FFmpegWrapper.cleanupOldTempDirectories()
                return (
                    FFmpegWrapper.toolVersion(name: "ffmpeg"),
                    FFmpegWrapper.toolVersion(name: "mediainfo")
                )
            }.value
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
        if !ffmpegStatus.contains("OK") || !miStatus.contains("OK") {
            self.showingToolErrorAlert = true; return
        }
        let savePanel = NSSavePanel()
        if #available(macOS 10.15, *) { savePanel.allowedContentTypes = [UTType.mpeg4Movie] } else { savePanel.allowedFileTypes = ["m4b", "mp4"] }
        savePanel.nameFieldStringValue = session.title.isEmpty ? "Hörbuch" : session.title
        savePanel.canCreateDirectories = true
        // Antwort-Behandlung gemeinsam, egal ob als Sheet oder modal gezeigt.
        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = savePanel.url {
                let finalURL = url.pathExtension.isEmpty ? url.appendingPathExtension("m4b") : url.deletingPathExtension().appendingPathExtension("m4b")
                let plan = FFmpegWrapper.makeConversionPlan(
                    files: session.audioFiles,
                    outputURL: finalURL,
                    maxDurationHours: session.settings.maxDurationHours
                )
                let collisions = plan.outputURLsRequiringOverwriteConfirmation
                if !collisions.isEmpty {
                    self.pendingPlan = plan
                    self.collidingOutputNames = collisions.map(\.lastPathComponent)
                    self.showingOverwriteAlert = true
                } else {
                    startConversion(plan)
                }
            }
        }
        // Kein Force-Unwrap auf NSApp.mainWindow (kann nil sein -> Crash).
        // Vorhandenes Fenster als Sheet-Parent nutzen, sonst Panel modal zeigen.
        if let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first {
            savePanel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(savePanel.runModal())
        }
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
                            TextField("Autor / Sprecher", text: $session.author).textFieldStyle(.roundedBorder)
                            Label("Genre", systemImage: "music.note")
                            TextField("Genre", text: $session.genre).textFieldStyle(.roundedBorder)
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
                            List {
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
                                }
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
                                    || resolveKloepplerURL() == nil
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
        .alert("Import nicht übernommen", isPresented: Binding(
            get: { session.importErrorMessage != nil },
            set: { if !$0 { session.importErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { session.importErrorMessage = nil }
        } message: {
            Text(session.importErrorMessage ?? "Unbekannter Analysefehler")
        }
        .alert("Konvertierung nicht gestartet", isPresented: Binding(
            get: { conversionStartError != nil },
            set: { if !$0 { conversionStartError = nil } }
        )) {
            Button("OK", role: .cancel) { conversionStartError = nil }
        } message: {
            Text(conversionStartError ?? "Unbekannter Startfehler")
        }
        .alert("CLI-Handoff fehlgeschlagen", isPresented: Binding(
            get: { cliHandoffError != nil },
            set: { if !$0 { cliHandoffError = nil } }
        )) {
            Button("OK", role: .cancel) { cliHandoffError = nil }
        } message: {
            Text(cliHandoffError ?? "Das Terminal konnte nicht geöffnet werden.")
        }
        .onAppear { checkTools() }
        .frame(minWidth: 850, minHeight: 650) // Fenster etwas höher gemacht (650 statt 550)
        .sheet(isPresented: $showingSettings) { SettingsView(session: session, isPresented: $showingSettings) }
        .alert("Datei existiert bereits", isPresented: $showingOverwriteAlert) {
            Button("Abbrechen", role: .cancel) { }
            Button("Drüberklöppeln", role: .destructive) {
                if let plan = pendingPlan { startConversion(plan) }
            }
        } message: {
            Text("Diese tatsächlichen Zieldateien existieren bereits:\n\(collidingOutputNames.joined(separator: "\n"))\n\nMöchten Sie sie wirklich überklöppeln?")
        }
        .sheet(isPresented: $session.showSelectionUI) { MetadataSelectionView(session: session) }
        .sheet(isPresented: $session.showInfoSheet) {
            VStack(spacing: 0) {
                HStack { Text("Datei-Details").font(.headline).padding(.leading); Spacer(); Button("Schließen") { session.showInfoSheet = false }.padding(.trailing) }.frame(height: 40).background(Color(NSColor.windowBackgroundColor))
                Divider()
                ZStack {
                    if session.isFetchingInfo { ProgressView() } else { ScrollView { Text(session.selectedFileInfoText).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(width: 700, height: 500)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in handleDroppedProviders(providers); return true }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) {
        let importToken = session.beginImport(expectedItemCount: providers.count)
        let currentSession = session
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in
                    guard let url else {
                        await currentSession.finishImport(importToken)
                        return
                    }
                    await currentSession.runImportTask(importToken) {
                        await Self.processDroppedURL(
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
    private static func processDroppedURL(
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

    private func startConversion(_ plan: ConversionPlan) {
        switch FFmpegWrapper.convert(session: session, plan: plan) {
        case .started:
            conversionStartError = nil
        case .rejected(let message):
            conversionStartError = message
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
        guard let kloepplerURL = resolveKloepplerURL() else {
            session.addLog("⚠️ CLI-Übergabe nicht möglich: Das Programm „kloeppler“ wurde nicht gefunden.")
            return
        }

        let invocation = CLIInvocation(
            executable: kloepplerURL.path,
            folderURL: folderURL,
            settings: session.settings,
            title: session.title,
            author: session.author,
            genre: session.genre,
            coverPath: session.coverPath,
            suppressCover: session.isCoverSuppressed
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

    private func resolveKloepplerURL() -> URL? {
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
        if resolveKloepplerURL() == nil {
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
