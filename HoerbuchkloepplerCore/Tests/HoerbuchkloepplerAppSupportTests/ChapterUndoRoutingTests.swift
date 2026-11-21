import AppKit
import AVFoundation
import Foundation
import Testing
@testable import HoerbuchkloepplerAppSupport
@testable import HoerbuchkloepplerCore

extension AppSupportTests {
    @Test("Text- und Kapitel-Undo im zugehörigen Fenster")
    func chapterAndTextUndo() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var activeWindow: NSWindow? = window
        let router = ChapterUndoRouter(activeWindow: { activeWindow })
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChapterUndoTest-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Kapitel.wav")
        try writeAudio(to: url)
        await session.importFiles([url], analyzeArtwork: false)
        try #require(session.audioFiles.count == 1, "Audioimport liefert das Kapitel für die Undo-Prüfung")
        let file = session.audioFiles[0]
        var stoppedPreview = 0
        router.configure(session: session, beforeChapterEdit: { stoppedPreview += 1 })
        router.attach(to: window)
        try #require(router.canUndo, "Projekt-Undo ist ohne Textfokus verfügbar")
        router.undo()
        try #require(session.audioFiles.isEmpty && stoppedPreview == 1, "Projekt-Undo stellt den vorherigen Stand her und stoppt die Vorschau")
        router.redo()
        try #require(session.audioFiles == [file] && stoppedPreview == 2, "Projekt-Redo stellt das Kapitel wieder her")

        let editor = NSTextView(frame: window.contentView!.bounds)
        editor.allowsUndo = true
        editor.string = "Alt"
        window.contentView = editor
        try #require(window.makeFirstResponder(editor), "Textfeld erhält den lokalen First Responder ohne sichtbares Fenster")
        editor.undoManager?.removeAllActions()
        router.refresh()
        try #require(!router.canUndo, "Leerer Textverlauf fällt nicht auf Projekt-Undo zurück")
        router.undo()
        try #require(session.audioFiles == [file], "Textfokus schützt den Projektverlauf")

        editor.undoManager?.beginUndoGrouping()
        editor.insertText("Neu", replacementRange: NSRange(location: 0, length: 3))
        editor.undoManager?.endUndoGrouping()
        router.refresh()
        try #require(editor.string == "Neu" && router.canUndo, "Echte Texteingabe registriert Undo")
        router.undo()
        try #require(editor.string == "Alt" && session.audioFiles == [file], "Text-Undo verändert ausschließlich Text")
        router.redo()
        try #require(editor.string == "Neu" && session.audioFiles == [file], "Text-Redo verändert ausschließlich Text")
        try #require(stoppedPreview == 2, "Text-Undo verändert die Kapitelvorschau nicht")

        window.makeFirstResponder(nil)
        let otherWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        activeWindow = otherWindow
        router.refresh()
        try #require(!router.canUndo && !router.canRedo, "Ein anderes aktives Fenster kann dieses Projekt nicht verändern")
        router.undo()
        try #require(session.audioFiles == [file], "Fremdes Fenster bleibt folgenlos")
        activeWindow = window
        let token = session.beginImport(expectedItemCount: 1)
        router.refresh()
        try #require(!router.canUndo && !router.canRedo, "Projekt-Undo bleibt während eines Imports gesperrt")
        router.undo()
        try #require(session.audioFiles == [file] && session.isImporting, "Undo bricht keinen laufenden Import ab")
        session.cancelImport()
        await session.finishImport(token)
        session.isConverting = true
        router.refresh()
        try #require(!router.canUndo && !router.canRedo, "Projekt-Undo bleibt während der Konvertierung gesperrt")
        session.isConverting = false
        router.refresh()
        try #require(router.canUndo, "Projekt-Undo wird nach der Konvertierung wieder verfügbar")
        try #require(!window.isVisible && !otherWindow.isVisible, "Die Prüfung hat keine Fenster angezeigt")
        print("GUI-Undo-Routing ohne Fokusübernahme bestanden.")
    }

    func writeAudio(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(buffer.frameLength))
        let audio = try AVAudioFile(forWriting: url, settings: format.settings)
        try audio.write(from: buffer)
    }
}
