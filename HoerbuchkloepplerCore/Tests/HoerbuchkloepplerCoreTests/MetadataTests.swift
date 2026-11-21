import Foundation
import Testing
@testable import HoerbuchkloepplerCore
import Darwin

@Suite("Tag-Auswahl und MediaInfo")
@MainActor
struct MetadataTests {
    @Test("Mehrdeutige oder fehlende Tags öffnen die manuelle Auswahl")
    func metadataSelectionDecision() {
        let ambiguous = [
            TagCandidate(type: "Tag", key: "Album", value: "A"),
            TagCandidate(type: "Tag", key: "Title", value: "B")
        ]
        let resolution = MediaInfoService.resolveMetadata(
            currentTitle: "",
            currentAuthor: "",
            titleCandidates: ambiguous,
            authorCandidates: []
        )
        #expect(resolution.title.isEmpty)
        #expect(resolution.author.isEmpty)
        #expect(resolution.shouldShowSelection)
    }

    @Test("Headless nimmt bei mehrdeutigen Tags den ersten Kandidaten statt leer zu bleiben")
    func headlessAmbiguityPrefersFirstCandidate() {
        // Kandidaten-Reihenfolge aus `metadataCandidates`: Album vor Title,
        // Performer vor Album_Performer. Die CLI hat keine Auswahl-UI und muss
        // deshalb selbst entscheiden.
        let resolution = MediaInfoService.resolveMetadata(
            currentTitle: "",
            currentAuthor: "",
            titleCandidates: [
                TagCandidate(type: "MediaInfo", key: "Album", value: "Buchtitel"),
                TagCandidate(type: "MediaInfo", key: "Title", value: "Kapitel 1")
            ],
            authorCandidates: [
                TagCandidate(type: "MediaInfo", key: "Performer", value: "Autor"),
                TagCandidate(type: "MediaInfo", key: "Album_Performer", value: "Verlag")
            ],
            allowsSelectionUI: false
        )
        #expect(resolution.title == "Buchtitel")
        #expect(resolution.author == "Autor")
        #expect(!resolution.shouldShowSelection)
    }

    @Test("Headless ohne brauchbare Kandidaten bleibt leer und verlangt keine Auswahl")
    func headlessWithoutCandidatesStaysEmpty() {
        let resolution = MediaInfoService.resolveMetadata(
            currentTitle: "",
            currentAuthor: "",
            titleCandidates: [],
            authorCandidates: [TagCandidate(type: "MediaInfo", key: "Performer", value: "   ")],
            allowsSelectionUI: false
        )
        #expect(resolution.title.isEmpty)
        #expect(resolution.author.isEmpty)
        #expect(!resolution.shouldShowSelection)
    }

    @Test("Metadatenwerte werden vor der Entscheidung bereinigt")
    func metadataValuesAreNormalized() {
        let resolution = MediaInfoService.resolveMetadata(
            currentTitle: "",
            currentAuthor: "",
            titleCandidates: [
                TagCandidate(type: "Tag", key: "Album", value: " Buch "),
                TagCandidate(type: "Tag", key: "Title", value: "Buch")
            ],
            authorCandidates: [
                TagCandidate(type: "Tag", key: "Artist", value: "   ")
            ]
        )
        #expect(resolution.title == "Buch")
        #expect(resolution.author.isEmpty)
        #expect(resolution.shouldShowSelection)
    }

    @Test("Je ein eindeutiger Tag wird automatisch übernommen")
    func uniqueMetadataIsFilled() {
        let resolution = MediaInfoService.resolveMetadata(
            currentTitle: "",
            currentAuthor: "",
            titleCandidates: [TagCandidate(type: "Tag", key: "Album", value: "Buch")],
            authorCandidates: [TagCandidate(type: "Tag", key: "Artist", value: "Autor")]
        )
        #expect(resolution.title == "Buch")
        #expect(resolution.author == "Autor")
        #expect(!resolution.shouldShowSelection)
    }

    @Test("UTF-16-MediaInfo-JSON wird erst nach erfolgreichem JSON-Parse akzeptiert")
    func utf16MediaInfoJSONIsDecoded() throws {
        let json = """
        {"media":{"track":[{"@type":"General","Album":"Buch","Performer":"Autor"}]}}
        """
        let data = try #require(json.data(using: .utf16))
        let general = try #require(MediaInfoService.decodeGeneralTrack(from: data))

        #expect(general["Album"] as? String == "Buch")
        #expect(general["Performer"] as? String == "Autor")
    }

    @Test("Rohe UTF-16-MediaInfo-Ausgabe wird nicht als MacRoman-Zeichensalat akzeptiert")
    func utf16MediaInfoTextIsDecoded() throws {
        let text = "Titel: Hörbuch"
        let data = try #require(text.data(using: .utf16))

        #expect(MediaInfoService.decodeText(from: data) == text)
    }

    @Test("Eine neue Dateiinfo beendet den alten MediaInfo-Prozess")
    func newerMediaInfoRequestTerminatesPreviousProcess() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("media-info.pid")
        let slowTool = directory.appendingPathComponent("langsam")
        let fastTool = directory.appendingPathComponent("schnell")
        // Die PID atomar einsetzen: `> "$1"` legt die Datei schon vor dem
        // Schreiben an, und der Test las sie unter Last als leeren String.
        try writeExecutable(slowTool, """
        #!/bin/sh
        printf '%s' "$$" > "$1.neu"
        mv "$1.neu" "$1"
        trap 'exit 0' TERM INT
        while :; do /bin/sleep 1; done
        """)
        try writeExecutable(fastTool, """
        #!/bin/sh
        printf 'Neue Datei\\n'
        """)

        let session = ConversionSession(settings: AudioSettings())
        session.mediaInfoExecutableProvider = { slowTool }
        session.fetchRawMediaInfo(for: AudioFile(
            url: pidFile,
            startTime: 0,
            duration: 1,
            chapterTitle: "Alt"
        ))

        // Auf eine LESBARE PID warten, nicht nur auf die Existenz der Datei.
        // Ein ausgelasteter Mac braucht bis zum Start des Werkzeugs länger als
        // die vorherigen zwei Sekunden.
        let startDeadline = Date().addingTimeInterval(20)
        var startedPID: pid_t?
        while startedPID == nil, Date() < startDeadline {
            startedPID = (try? String(contentsOf: pidFile, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if startedPID == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let oldPID = try #require(startedPID)
        defer {
            if Darwin.kill(oldPID, 0) == 0 {
                _ = Darwin.kill(oldPID, SIGKILL)
            }
        }

        session.mediaInfoExecutableProvider = { fastTool }
        session.fetchRawMediaInfo(for: AudioFile(
            url: directory.appendingPathComponent("neu.m4b"),
            startTime: 0,
            duration: 1,
            chapterTitle: "Neu"
        ))

        let resultDeadline = Date().addingTimeInterval(20)
        while session.isFetchingInfo, Date() < resultDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.selectedFileInfoText.contains("Neue Datei"))

        let exitDeadline = Date().addingTimeInterval(20)
        while Darwin.kill(oldPID, 0) == 0, Date() < exitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(Darwin.kill(oldPID, 0) == -1 && errno == ESRCH)
    }
}
