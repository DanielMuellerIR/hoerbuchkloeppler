import AppKit

public enum WindowAlert {
    case error(title: String, message: String)
    case openProject(URL)
    case retryImport
    case overwrite(filenames: [String])

    var title: String {
        switch self {
        case .error(let title, _): title
        case .openProject: "Projekt öffnen?"
        case .retryImport: "Import hat zu lange gewartet"
        case .overwrite: "Datei existiert bereits"
        }
    }

    var message: String {
        switch self {
        case .error(_, let message):
            message
        case .openProject(let url):
            "Das aktuelle Hörbuch wird durch \(url.lastPathComponent) ersetzt. Nicht gespeicherte Änderungen gehen dabei verloren."
        case .retryImport:
            "Der Drag-and-drop-Import hat nach 60 Sekunden noch nicht alle Dateien bereitgestellt. Der neue Import wurde verworfen. Das bisherige Hörbuch bleibt erhalten."
        case .overwrite(let filenames):
            "Diese Zieldateien existieren bereits:\n\(filenames.joined(separator: "\n"))\n\nMöchten Sie sie überschreiben?"
        }
    }

    @MainActor func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let action: String
        switch self {
        case .error:
            alert.addButton(withTitle: "OK")
            return alert
        case .retryImport: action = "Wiederholen"
        case .openProject: action = "Projekt öffnen"
        case .overwrite: action = "Drüberklöppeln"
        }
        let primary = alert.addButton(withTitle: action)
        switch self {
        case .openProject, .overwrite:
            primary.hasDestructiveAction = true
            primary.keyEquivalent = ""
        case .error, .retryImport: break
        }
        alert.addButton(withTitle: "Abbrechen").keyEquivalent = "\u{1b}"
        return alert
    }
}
