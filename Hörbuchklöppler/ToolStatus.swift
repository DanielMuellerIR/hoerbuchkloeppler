struct ToolStatus {
    enum Availability: Equatable {
        case checking
        case available(version: String)
        case unavailable

        var text: String {
            switch self {
            case .checking: "Prüfe …"
            case .available(let version): "OK (\(version))"
            case .unavailable: "Nicht verfügbar"
            }
        }
    }

    enum ExportAvailability: Equatable {
        case checking
        case available
        case unavailable(message: String)
    }

    var ffmpeg = Availability.checking
    var mediaInfo = Availability.checking

    var exportAvailability: ExportAvailability {
        guard ffmpeg != .checking, mediaInfo != .checking else { return .checking }
        let tools = [("FFmpeg", ffmpeg), ("MediaInfo", mediaInfo)]
        let unavailable = tools.filter { $0.1 == .unavailable }.map { $0.0 }
        guard !unavailable.isEmpty else { return .available }
        return .unavailable(message: """
            Für den Export muss die App FFmpeg und MediaInfo starten können. Nicht verfügbar: \(unavailable.joined(separator: ", ")).

            Hörbuchklöppler bringt beide Programme mit. Installieren Sie die App erneut, wenn die mitgelieferten Programme fehlen oder nicht starten.

            Falls die mitgelieferten Programme fehlen, kann die App sie auch aus einer Homebrew-Installation verwenden.
            """)
    }
}
