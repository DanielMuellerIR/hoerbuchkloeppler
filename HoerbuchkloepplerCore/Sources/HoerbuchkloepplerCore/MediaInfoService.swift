import Foundation

public struct TagCandidate: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let type: String
    public let key: String
    public let value: String
    public init(type: String, key: String, value: String) { self.type = type; self.key = key; self.value = value }
}

struct MetadataResolution: Equatable, Sendable {
    let title: String
    let author: String
    let shouldShowSelection: Bool
}

enum MediaInfoService {
    static func readText(
        for fileURL: URL,
        executableURL: URL?,
        context: ToolProcessContext
    ) -> String {
        guard let executableURL else {
            return "MediaInfo wurde auf diesem System nicht gefunden."
        }
        switch ProcessRunner.capture(
            executableURL: executableURL,
            arguments: [fileURL.path],
            context: context,
            timeout: 10
        ) {
        case .completed(let status, let data) where status == 0:
            guard !data.isEmpty else {
                return "MediaInfo hat keine Informationen geliefert."
            }
            return decodeText(from: data) ?? "Dekodierung fehlgeschlagen."
        case .timedOut:
            return "MediaInfo wurde nach 10 Sekunden beendet."
        case .cancelled:
            return "MediaInfo-Abfrage wurde abgebrochen."
        case .completed(let status, _):
            return "MediaInfo endete mit Exit-Code \(status)."
        case .failed(let reason):
            return "Fehler: \(reason)"
        }
    }

    static func decodeText(from data: Data) -> String? {
        encodings(for: data, probeUnmarkedUTF16: false).lazy
            .compactMap { String(data: data, encoding: $0) }.first
    }

    static func readTitleAndAuthor(
        for file: URL,
        context: ToolProcessContext?
    ) -> (titles: [TagCandidate], authors: [TagCandidate])? {
        guard context?.isCancelled != true,
              let executable = ToolLocator.binaryURL(name: "mediainfo") else { return nil }
        let result = ProcessRunner.capture(
            executableURL: executable,
            arguments: ["--Output=JSON", file.path],
            context: context,
            timeout: 10
        )
        guard case .completed(let status, let data) = result, status == 0,
              context?.isCancelled != true,
              let general = decodeGeneralTrack(from: data) else { return nil }
        return metadataCandidates(from: general)
    }

    static func decodeGeneralTrack(from data: Data) -> [String: Any]? {
        // Pro Zeichensatz erst den JSON-Parse prüfen. MacRoman/Latin-1 können
        // fast jede Bytefolge als Text darstellen und dürfen einen später
        // tatsächlich passenden UTF-16-Versuch nicht vorzeitig verdrängen.
        for encoding in encodings(for: data, probeUnmarkedUTF16: true) {
            guard let text = String(data: data, encoding: encoding),
                  let start = text.firstIndex(of: "{"),
                  let end = text.lastIndex(of: "}"),
                  start <= end,
                  let jsonData = String(text[start...end]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: jsonData),
                  let root = object as? [String: Any],
                  let media = root["media"] as? [String: Any],
                  let tracks = media["track"] as? [[String: Any]],
                  let general = tracks.first(where: { $0["@type"] as? String == "General" }) else {
                continue
            }
            return general
        }
        return nil
    }

    private static func metadataCandidates(
        from general: [String: Any]
    ) -> (titles: [TagCandidate], authors: [TagCandidate]) {
        func value(for key: String) -> String? {
            general[key] as? String ?? (general[key] as? [String])?.first
        }
        var titles: [TagCandidate] = []
        var authors: [TagCandidate] = []
        if let album = value(for: "Album") {
            titles.append(TagCandidate(type: "MediaInfo", key: "Album", value: album))
        }
        if let title = value(for: "Title") {
            titles.append(TagCandidate(type: "MediaInfo", key: "Title", value: title))
        }
        if let performer = value(for: "Performer") {
            authors.append(TagCandidate(type: "MediaInfo", key: "Performer", value: performer))
        }
        if let albumPerformer = value(for: "Album_Performer") {
            authors.append(TagCandidate(type: "MediaInfo", key: "Album_Performer", value: albumPerformer))
        }
        return (titles, authors)
    }

    /// `allowsSelectionUI: false` ist der headless-Pfad (CLI): Bei mehrdeutigen
    /// Kandidaten gewinnt der erste in Listenreihenfolge — also Album vor Title
    /// bzw. Performer vor Album_Performer (siehe `metadataCandidates`) — statt
    /// den Wert leer zu lassen. In der GUI führt Mehrdeutigkeit zur manuellen Auswahl.
    static func resolveMetadata(
        currentTitle: String,
        currentAuthor: String,
        titleCandidates: [TagCandidate],
        authorCandidates: [TagCandidate],
        allowsSelectionUI: Bool = true
    ) -> MetadataResolution {
        func resolve(current: String, candidates: [TagCandidate]) -> (String, Bool) {
            guard current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return (current, false)
            }
            let values = candidates
                .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let uniqueValues = Array(Set(values)).sorted()
            if uniqueValues.count == 1 { return (uniqueValues[0], false) }
            guard allowsSelectionUI else {
                // Headless: erster nichtleerer Kandidat oder unverändert leer.
                return (values.first ?? current, false)
            }
            return (current, true)
        }

        let resolvedTitle = resolve(current: currentTitle, candidates: titleCandidates)
        let resolvedAuthor = resolve(current: currentAuthor, candidates: authorCandidates)
        return MetadataResolution(
            title: resolvedTitle.0,
            author: resolvedAuthor.0,
            shouldShowSelection: resolvedTitle.1 || resolvedAuthor.1
        )
    }

    private static func encodings(for data: Data, probeUnmarkedUTF16: Bool) -> [String.Encoding] {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return [.utf16, .utf8, .macOSRoman, .isoLatin1]
        }
        // Nur JSON kann anhand seiner Struktur bestätigen, dass eine unmarkierte
        // Bytefolge tatsächlich UTF-16 ist.
        return probeUnmarkedUTF16 ? [.utf8, .utf16, .macOSRoman, .isoLatin1] : [.utf8, .macOSRoman, .isoLatin1]
    }
}
