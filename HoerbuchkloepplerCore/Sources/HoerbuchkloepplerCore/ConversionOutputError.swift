import Darwin
import Foundation

enum ConversionOutputError: LocalizedError {
    case destinationChanged(URL)
    case destinationInaccessible(URL, Int32)
    case destinationDirectoryChanged(URL)
    case destinationDirectoryInaccessible(URL, Int32)
    case destinationIsDirectory(URL)
    case destinationAliasesInput(URL, URL)
    case destinationBusy(URL)
    case lockFailed(URL, Int32)
    case restoreFailed(URL, recoveryURL: URL?, errno: Int32)
    case stagingChanged(URL)
    case sourceChanged(URL)
    case sourceInaccessible(URL, Int32)
    case invalidChapterTime(URL)
    case noInputFiles

    var errorDescription: String? {
        switch self {
        case .noInputFiles:
            return "Keine Audiodateien zum Konvertieren vorhanden."
        case .destinationChanged(let url):
            return "Die Zieldatei wurde seit der Bestätigung verändert: \(url.path)"
        case .destinationInaccessible(let url, let number):
            return
                "Die Zieldatei kann nicht sicher geprüft werden: \(url.path) (\(Self.reason(number)))"
        case .destinationDirectoryChanged(let url):
            return "Der Ausgabeordner wurde seit der Planung ersetzt: \(url.path)"
        case .destinationDirectoryInaccessible(let url, let number):
            return
                "Der Ausgabeordner kann nicht sicher geprüft werden: \(url.path) (\(Self.reason(number)))"
        case .destinationIsDirectory(let url):
            return "Der Zielpfad ist ein Ordner und wird nicht ersetzt: \(url.path)"
        case .destinationAliasesInput(let output, let input):
            return "Die Ausgabe verweist auf eine Eingabedatei: \(output.path) → \(input.path)"
        case .destinationBusy(let url):
            return "Ein anderer Hörbuchklöppler-Lauf verwendet bereits dieses Ziel: \(url.path)"
        case .lockFailed(let url, let number):
            return
                "Das Ziel konnte nicht exklusiv reserviert werden: \(url.path) (\(Self.reason(number)))"
        case .restoreFailed(let url, let recoveryURL, let number):
            let recovery =
                recoveryURL.map {
                    " Der verdrängte Eintrag bleibt zur manuellen Wiederherstellung unter \($0.path) erhalten."
                } ?? ""
            return
                "Die zwischenzeitlich geänderte Zieldatei konnte nicht zurückgetauscht werden: \(url.path) (\(Self.reason(number))).\(recovery)"
        case .stagingChanged(let url):
            return
                "Die temporäre Ausgabedatei wurde während der Übernahme ausgetauscht und bleibt unangetastet: \(url.path)"
        case .sourceChanged(let url):
            return "Eine Eingabedatei wurde seit der Planung verändert: \(url.path)"
        case .sourceInaccessible(let url, let number):
            return
                "Eine Eingabedatei kann nicht sicher gelesen werden: \(url.path) (\(Self.reason(number)))"
        case .invalidChapterTime(let url):
            return "Die Kapitelzeiten können nicht ausgegeben werden: \(url.lastPathComponent)"
        }
    }

    private static func reason(_ number: Int32) -> String {
        String(cString: strerror(number))
    }
}
