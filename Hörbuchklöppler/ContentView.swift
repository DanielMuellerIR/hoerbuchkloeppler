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
            self?.stop()
        }
        player = p
        playingID = file.id
        p.seek(to: CMTime(seconds: file.startTime, preferredTimescale: 600)) { [weak p] _ in p?.play() }
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
    @State private var pendingURL: URL? = nil
    @StateObject var session = ConversionSession()
    @StateObject private var preview = ChapterPreviewPlayer()
    @State private var showingSettings = false
    @State private var selectedFile: AudioFile? = nil
    @State private var ffmpegStatus = "Prüfe..."
    @State private var miStatus = "Prüfe..."
    @State private var showingToolErrorAlert = false

    // ... (checkTools und getToolVersion bleiben identisch zum Original)
    func checkTools() {
        FFmpegWrapper.cleanupOldTempDirectories()
        
        let ffmpegURL = FFmpegWrapper.getBinaryURL(name: "ffmpeg")
        let miURL = FFmpegWrapper.getBinaryURL(name: "mediainfo")

        if let fURL = ffmpegURL {
            let version = getToolVersion(path: fURL.path)
            self.ffmpegStatus = "OK (\(version))"
            session.addLog("🛠️ FFmpeg gefunden an \(fURL.path) (Version: \(version))")
        } else {
            self.ffmpegStatus = "Nicht gefunden"
            session.addLog("❌ FFmpeg NICHT gefunden!")
        }

        if let mURL = miURL {
            let version = getToolVersion(path: mURL.path)
            self.miStatus = "OK (\(version))"
            session.addLog("🛠️ MediaInfo gefunden an \(mURL.path) (Version: \(version))")
        } else {
            self.miStatus = "Nicht gefunden"
            session.addLog("❌ MediaInfo NICHT gefunden!")
        }
        
        session.logCurrentSettings() // Einstellungen direkt beim Start loggen
    }

    private func getToolVersion(path: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = path.contains("mediainfo") ? ["--version"] : ["-version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe // Fehler ebenfalls abfangen
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                // Suche nach dem Wort "version" und nimm das darauf folgende Wort
                let parts = output.components(separatedBy: .whitespacesAndNewlines)
                if let index = parts.firstIndex(of: "version"), index + 1 < parts.count {
                    return parts[index + 1].replacingOccurrences(of: ",", with: "")
                }
                // Fallback für MediaInfo (oft v24.x)
                if path.contains("mediainfo") {
                    for part in parts {
                        if part.starts(with: "v") && part.contains(".") { return part }
                    }
                }
                return parts.first ?? "gefunden"
            }
        } catch { return "Fehler" }
        return "leer"
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
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    self.pendingURL = finalURL; self.showingOverwriteAlert = true
                } else { FFmpegWrapper.convert(session: session, outputURL: finalURL) }
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
        ZStack { // NEU: ZStack für das Overlay
            HSplitView {
                // --- Linke Sidebar (Cover & Metadaten) ---
                VStack(spacing: 20) {
                    VStack {
                        CoverView(image: $session.coverImage, onDropped: { url in session.selectCover(url: url) })
                            .frame(width: 180, height: 180).shadow(radius: 5)
                        if session.coverImage != nil || session.coverPath != nil {
                            Button(action: { session.coverImage = nil; session.coverPath = nil; session.embeddedCoverData = nil }) {
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
                                Button("Alle löschen") { preview.stop(); session.audioFiles.removeAll() }
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
                        .disabled(session.isConverting || session.audioFiles.isEmpty)
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
                            .disabled(session.audioFiles.isEmpty)
                            .help("Öffnet das Terminal mit dem passenden Befehl für die aktuellen Einstellungen.")
                        }
                        .padding(.trailing, 20)
                        .padding(.bottom, 10)
                    }
                    .frame(height: 130)
                }
            }

            // NEU: Das Konversions-Overlay
            if session.showOverlay { // GEÄNDERT von session.isConverting
                ConversionOverlayView(session: session)
                    .transition(.opacity)
                    .zIndex(10)
                    .onAppear {
                        DispatchQueue.main.async {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        }
                    }
            }
        }
        .alert("Tools fehlen", isPresented: $showingToolErrorAlert) { Button("OK", role: .cancel) { } } message: {
            Text("Für die Konvertierung werden FFmpeg und MediaInfo benötigt.\n\nBitte installieren Sie Homebrew und führen Sie im Terminal aus:\nbrew install ffmpeg mediainfo")
        }
        .onAppear { checkTools() }
        .frame(minWidth: 850, minHeight: 650) // Fenster etwas höher gemacht (650 statt 550)
        .sheet(isPresented: $showingSettings) { SettingsView(session: session, isPresented: $showingSettings) }
        .alert("Datei existiert bereits", isPresented: $showingOverwriteAlert) {
            Button("Abbrechen", role: .cancel) { }
            Button("Drüberklöppeln", role: .destructive) { if let url = pendingURL { FFmpegWrapper.convert(session: session, outputURL: url) } }
        } message: { Text("Möchten Sie die vorhandene Datei wirklich überklöppeln?") }
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
        for provider in providers { _ = provider.loadObject(ofClass: URL.self) { url, error in DispatchQueue.main.async { if let url = url { self.processDroppedURL(url) } } } }
    }

    private func processDroppedURL(_ url: URL) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            // Ordner-Scan (ffmpeg-Kapitel-Extraktion + AVAsset-Reads über viele Dateien)
            // im Hintergrund, damit die UI beim Drop großer Ordner nicht einfriert.
            // Nur das Übernehmen in den @Published-State läuft danach auf Main.
            DispatchQueue.global(qos: .userInitiated).async {
                let scanned = session.scanFolder(url)
                DispatchQueue.main.async { session.applyScannedFolder(scanned) }
            }
        } else { processSingleFile(url) }
    }

    private func processSingleFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        // Auch Einzeldatei-Import (Kapitel-Extraktion / Dauer-Lesen) im Hintergrund;
        // der @Published-Zugriff (processIncomingFiles) danach auf Main.
        DispatchQueue.global(qos: .userInitiated).async {
            let files: [AudioFile]?
            if ["m4b", "mp4"].contains(ext) { files = AudioFile.extractChapters(from: url) }
            else if ["mp3", "m4a", "wav", "flac"].contains(ext) { files = [AudioFile(url: url)] }
            else { files = nil }
            if let files = files {
                DispatchQueue.main.async { session.processIncomingFiles(files) }
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
        let mode = session.settings.useParallelEncoding ? "parallel" : "standard"
        let mono = session.settings.isMono ? "--mono" : "--stereo"
        let folderPath = session.audioFiles.first?.url.deletingLastPathComponent().path ?? "/Pfad/zum/Hoerbuch"

        // Das kloeppler-Binary wirklich auflösen statt blind "./kloeppler"
        // anzunehmen: In einem installierten Build (z.B. /Applications) liegt
        // neben der App kein Binary. Reihenfolge: neben der App (Testbuild im
        // Repo-Root), Entwicklungs-Build im Repo, dann PATH/übliche
        // Installationsorte (getBinaryURL).
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let candidates = [
            appDir.appendingPathComponent("kloeppler"),
            appDir.appendingPathComponent("HoerbuchkloepplerCore/.build/release/kloeppler")
        ]
        let kloepplerURL = candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
            ?? FFmpegWrapper.getBinaryURL(name: "kloeppler")

        // Ohne Fund bleibt der nackte Befehl (kloeppler liegt evtl. im PATH der
        // Login-Shell); der absolute Pfad steht in Anführungszeichen, damit
        // Leerzeichen/Umlaute im Repo-Pfad nicht stören.
        let kloepplerCmd = kloepplerURL.map { "\"\($0.path)\"" } ?? "kloeppler"
        let cmd = "\(kloepplerCmd) \"\(folderPath)\" --mode \(mode) --bitrate \(session.settings.bitrate) --samplerate \(session.settings.sampleRate) \(mono)"

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)

        // Terminal dort öffnen, wo das Binary liegt; ohne Fund im Home statt in
        // einem App-Verzeichnis ohne Binary.
        let openDirectory = kloepplerURL?.deletingLastPathComponent().path ?? NSHomeDirectory()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", openDirectory]
        try? process.run()
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
            if let provider = providers.first { _ = provider.loadObject(ofClass: URL.self) { url, _ in DispatchQueue.main.async { if let url = url { self.onDropped(url) } } } }
            return true
        }
    }
}
