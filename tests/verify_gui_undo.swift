import AppKit
import Foundation
import HoerbuchkloepplerCore

@main
struct UndoCheck {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var activeWindow: NSWindow? = window
        let router = ChapterUndoRouter(activeWindow: { activeWindow })
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        let file = AudioFile(url: URL(fileURLWithPath: "/tmp/undo-fixture.wav"),
                             startTime: 0, duration: 1, chapterTitle: "Kapitel")
        session.audioFiles = [file]
        var stoppedPreview = 0
        router.configure(session: session, beforeChapterEdit: { stoppedPreview += 1 })
        router.attach(to: window)
        require(router.canUndo, "Projekt-Undo ist ohne Textfokus verfügbar")
        router.undo()
        require(session.audioFiles.isEmpty && stoppedPreview == 1, "Projekt-Undo stellt den vorherigen Stand her und stoppt die Vorschau")
        router.redo()
        require(session.audioFiles == [file] && stoppedPreview == 2, "Projekt-Redo stellt das Kapitel wieder her")

        let editor = NSTextView(frame: window.contentView!.bounds)
        editor.allowsUndo = true
        editor.string = "Alt"
        window.contentView = editor
        require(window.makeFirstResponder(editor), "Textfeld erhält den lokalen First Responder ohne sichtbares Fenster")
        editor.undoManager?.removeAllActions()
        router.refresh()
        require(!router.canUndo, "Leerer Textverlauf fällt nicht auf Projekt-Undo zurück")
        router.undo()
        require(session.audioFiles == [file], "Textfokus schützt den Projektverlauf")

        editor.undoManager?.beginUndoGrouping()
        editor.insertText("Neu", replacementRange: NSRange(location: 0, length: 3))
        editor.undoManager?.endUndoGrouping()
        router.refresh()
        require(editor.string == "Neu" && router.canUndo, "Echte Texteingabe registriert Undo")
        router.undo()
        require(editor.string == "Alt" && session.audioFiles == [file], "Text-Undo verändert ausschließlich Text")
        router.redo()
        require(editor.string == "Neu" && session.audioFiles == [file], "Text-Redo verändert ausschließlich Text")
        require(stoppedPreview == 2, "Text-Undo verändert die Kapitelvorschau nicht")

        window.makeFirstResponder(nil)
        let otherWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        activeWindow = otherWindow
        router.refresh()
        require(!router.canUndo && !router.canRedo, "Ein anderes aktives Fenster kann dieses Projekt nicht verändern")
        router.undo()
        require(session.audioFiles == [file], "Fremdes Fenster bleibt folgenlos")
        activeWindow = window
        let token = session.beginImport(expectedItemCount: 1)
        router.refresh()
        require(!router.canUndo && !router.canRedo, "Projekt-Undo bleibt während eines Imports gesperrt")
        router.undo()
        require(session.audioFiles == [file] && session.isImporting, "Undo bricht keinen laufenden Import ab")
        session.cancelImport()
        await session.finishImport(token)
        session.isConverting = true
        router.refresh()
        require(!router.canUndo && !router.canRedo, "Projekt-Undo bleibt während der Konvertierung gesperrt")
        session.isConverting = false
        router.refresh()
        require(router.canUndo, "Projekt-Undo wird nach der Konvertierung wieder verfügbar")
        require(!window.isVisible && !otherWindow.isVisible, "Die Prüfung hat keine Fenster angezeigt")
        print("GUI-Undo-Routing ohne Fokusübernahme bestanden.")
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FEHLER: \(message)\n", stderr)
            exit(1)
        }
    }
}
