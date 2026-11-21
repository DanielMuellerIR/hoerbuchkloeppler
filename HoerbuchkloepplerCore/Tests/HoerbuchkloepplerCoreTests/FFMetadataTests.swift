import Foundation
import Testing
@testable import HoerbuchkloepplerCore
import Darwin

@Suite("FFmpegWrapper – escapeFFMetadata")
struct EscapeFFMetadataTests {

    @Test("Gleichheitszeichen wird escaped")
    func escapesEqualsSign() {
        // "=" trennt im FFMETADATA1-Format Schlüssel von Wert.
        #expect(FFMetadata.escape("a=b") == "a\\=b")
    }

    @Test("Semikolon wird escaped")
    func escapesSemicolon() {
        // ";" leitet einen Kommentar ein — unescaped würde der Rest verschluckt.
        #expect(FFMetadata.escape("a;b") == "a\\;b")
    }

    @Test("Raute wird escaped")
    func escapesHash() {
        // "#" leitet ebenfalls einen Kommentar ein.
        #expect(FFMetadata.escape("a#b") == "a\\#b")
    }

    @Test("Backslash in der Mitte wird verdoppelt")
    func escapesBackslash() {
        #expect(FFMetadata.escape("a\\b") == "a\\\\b")
    }

    @Test("Zeilenumbruch wird zu Leerzeichen, nicht escaped")
    func newlineBecomesSpace() {
        // Ein Kapiteltitel ist einzeilig. Ein echter Umbruch — auch ein escapeter —
        // würde die chapters.txt zerreißen, deshalb wird er ersetzt statt maskiert.
        #expect(FFMetadata.escape("a\nb") == "a b")
        #expect(FFMetadata.escape("a\rb") == "a b")
        #expect(FFMetadata.escape("a\r\nb") == "a b")
    }

    @Test("Backslash am Ende wird entfernt")
    func trailingBackslashDropped() {
        // ffmpeg liest JEDEN Backslash am Zeilenende als Zeilenfortsetzung — auch
        // den maskierten. Bliebe er stehen, würde die folgende [CHAPTER]-Zeile
        // verschluckt und ein Kapitel ginge verloren.
        #expect(FFMetadata.escape("Titel\\") == "Titel")
        #expect(FFMetadata.escape("Titel\\\\") == "Titel")
    }

    @Test("Normaler Text bleibt unverändert")
    func normalTextUnchanged() {
        let normal = "Hörspiel Band 1"
        #expect(FFMetadata.escape(normal) == normal)
    }

    @Test("Mehrere Sonderzeichen werden alle escaped")
    func multipleSonderzeichen() {
        #expect(FFMetadata.escape("Titel=Wert;#") == "Titel\\=Wert\\;\\#")
    }
}

@Suite("Round-Trip Escape ↔ Unescape")
struct RoundTripTests {

    @Test("Normaler Text überlebt Round-Trip")
    func roundTripNormalText() {
        let original = "Kapitel 1 – Der Anfang"
        let back = FFMetadata.unescape(FFMetadata.escape(original))
        #expect(back == original)
    }

    @Test("Sonderzeichen überleben Round-Trip")
    func roundTripSonderzeichen() {
        let original = "Titel=Wert;#Kommentar"
        let back = FFMetadata.unescape(FFMetadata.escape(original))
        #expect(back == original)
    }

    @Test("Backslash in der Mitte überlebt Round-Trip")
    func roundTripInnerBackslash() {
        let original = "Pfad\\Datei"
        let back = FFMetadata.unescape(FFMetadata.escape(original))
        #expect(back == original)
    }

    @Test("Backslash am Ende überlebt den Round-Trip NICHT — bewusst")
    func roundTripTrailingBackslashIsLossy() {
        // Dokumentiert eine akzeptierte Verlustigkeit: ffmpeg kann einen
        // abschließenden Backslash ohnehin nicht verlustfrei zurücklesen.
        // Der Test hält fest, dass das Absicht ist und nicht versehentlich kippt.
        let back = FFMetadata.unescape(FFMetadata.escape("Titel\\"))
        #expect(back == "Titel")
    }
}

@Suite("FFmpegWrapper – buildChapterMetadata")
struct BuildChapterMetadataTests {

    private func file(_ title: String, _ duration: TimeInterval) -> AudioFile {
        AudioFile(url: URL(fileURLWithPath: "/tmp/\(title).mp3"), startTime: 0, duration: duration, chapterTitle: title)
    }

    @Test("Leere Gruppe ergibt nur den Header")
    func emptyGroup() {
        #expect(FFMetadata.encodeChapters(group: []) == ";FFMETADATA1\n")
    }

    @Test("Ein Kapitel bekommt START=0 und END=Dauer in Millisekunden")
    func singleChapter() {
        let meta = FFMetadata.encodeChapters(group: [file("Kapitel 1", 10)])
        #expect(meta.contains("START=0\n"))
        #expect(meta.contains("END=10000\n"))
        #expect(meta.contains("title=Kapitel 1\n"))
        #expect(meta.contains("TIMEBASE=1/1000"))
    }

    @Test("Kapitel liegen lückenlos hintereinander")
    func chaptersAreSequential() {
        // Zweites Kapitel muss exakt dort beginnen, wo das erste endet — sonst
        // entstehen Lücken oder Überlappungen in der Kapitelnavigation.
        let meta = FFMetadata.encodeChapters(group: [file("Eins", 10), file("Zwei", 5)])
        #expect(meta.contains("START=0\nEND=10000"))
        #expect(meta.contains("START=10000\nEND=15000"))
    }

    @Test("Kapiteltitel mit Sonderzeichen wird escaped")
    func titleIsEscaped() {
        let meta = FFMetadata.encodeChapters(group: [file("A=B;C", 1)])
        #expect(meta.contains("title=A\\=B\\;C"))
    }

    @Test("Kapitel mit Dauer 0 erzeugt START==END")
    func zeroDurationChapter() {
        // Hält das reale Verhalten fest: die Filterung solcher Dateien passiert
        // erst beim Kodieren, nicht hier.
        let meta = FFMetadata.encodeChapters(group: [file("Leer", 0)])
        #expect(meta.contains("START=0\nEND=0"))
    }
}

@Suite("AudioFile – parseFFMetadataChapters")
struct ParseFFMetadataChaptersTests {

    @Test("Eingebettetes Artwork braucht ein dekodierbares Bild innerhalb der Größenobergrenze")
    func validatesEmbeddedArtwork() throws {
        let png = try onePixelPNGData()

        #expect(AudioFile.validatedEmbeddedArtworkData(png) == png)
        #expect(AudioFile.validatedEmbeddedArtworkData(Data("kein Bild".utf8)) == nil)
        #expect(AudioFile.validatedEmbeddedArtworkData(
            Data(count: CoverArtwork.maximumByteCount + 1)
        ) == nil)
    }

    @Test("Einfache Kapitel werden gelesen")
    func parsesSimpleChapters() {
        let text = """
        ;FFMETADATA1
        [CHAPTER]
        TIMEBASE=1/1000
        START=0
        END=10000
        title=Kapitel 1
        [CHAPTER]
        TIMEBASE=1/1000
        START=10000
        END=20000
        title=Kapitel 2
        """
        let chapters = FFMetadata.decodeChapters(text)
        #expect(chapters.count == 2)
        #expect(chapters[0].start == 0)
        #expect(chapters[0].end == 10)
        #expect(chapters[0].title == "Kapitel 1")
        #expect(chapters[1].start == 10)
        #expect(chapters[1].end == 20)
    }

    @Test("Ein Zeilenumbruch im Titel bricht weder Titel noch Kapitelende")
    func keepsEscapedNewlineInsideTitle() {
        // ffmpeg escapt einen Umbruch im Wert als Backslash plus echten Umbruch.
        // Die Fortsetzungszeile darf nicht als eigenes Schlüssel/Wert-Paar
        // gelesen werden — sonst überschriebe ein Titel das echte END.
        let text = "[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\n"
            + "title=Vorwort\\\nEND=180000\n"
        let chapters = FFMetadata.decodeChapters(text)
        #expect(chapters.count == 1)
        #expect(chapters[0].end == 1)
        #expect(chapters[0].title == "Vorwort\nEND=180000")
    }

    @Test("Viele Fortsetzungszeilen werden vollständig zusammengefügt")
    func manyMetadataContinuationLines() throws {
        let pieces = Array(repeating: "x\\", count: 10_000) + ["Ende"]
        let lines = FFMetadata.logicalLines(pieces.joined(separator: "\n"))
        try #require(lines.count == 1)
        #expect(lines[0].hasSuffix("\nEnde"))
        #expect(lines[0].filter { $0 == "\n" }.count == 10_000)
    }

    @Test("CRLF-Zeilenenden liefern dieselben Kapitel wie LF")
    func parsesCarriageReturnLineEndings() throws {
        // `CharacterSet.whitespaces` enthält kein CR; vorher blieb von einer
        // handgepflegten CRLF-Datei kein einziges Kapitel übrig.
        let text = "[CHAPTER]\r\nTIMEBASE=1/1000\r\nSTART=0\r\nEND=1000\r\ntitle=Eins\r\n"
            + "[CHAPTER]\r\nSTART=1000\r\nEND=2000\r\ntitle=Zwei\r\n"
        let chapters = FFMetadata.decodeChapters(text)
        try #require(chapters.count == 2)
        #expect(chapters[0].start == 0)
        #expect(chapters[0].end == 1)
        #expect(chapters[0].title == "Eins")
        #expect(chapters[1].start == 1)
        #expect(chapters[1].end == 2)
        #expect(chapters[1].title == "Zwei")
    }

    @Test("Ein END vor dem START wird nicht stillschweigend repariert")
    func doesNotRepairInvertedChapterBounds() throws {
        // Fehlt END, füllt der Parser aus dem nächsten Kapitel. Ein
        // ausdrücklich widersprüchliches Paar bleibt dagegen ungültig, damit
        // die Extraktion auf das sichere Ein-Kapitel-Ergebnis zurückfällt,
        // statt ein Kapitel zu erfinden.
        let text = """
        [CHAPTER]
        TIMEBASE=1/1000
        START=0
        END=4000
        title=Eins
        [CHAPTER]
        START=4000
        END=2000
        title=Verdreht
        [CHAPTER]
        START=9000
        END=12000
        title=Drei
        """
        let chapters = FFMetadata.decodeChapters(text)
        try #require(chapters.count == 3)
        #expect(chapters[1].start == 4)
        #expect(chapters[1].end == 2)
        #expect(!FFMetadata.chaptersAreValid(chapters, totalDuration: 12))
    }

    @Test("Ein explizites END auf START bleibt ungültig")
    func doesNotRepairZeroLengthChapter() throws {
        let text = """
        [CHAPTER]
        START=0
        END=0
        title=Leer
        [CHAPTER]
        START=5000
        END=9000
        title=Zwei
        """
        let chapters = FFMetadata.decodeChapters(text)
        try #require(chapters.count == 2)
        #expect(chapters[0].end == 0)
        #expect(!FFMetadata.chaptersAreValid(chapters, totalDuration: 9))
    }

    @Test("Nur ein fehlendes letztes END wird durch die Dateidauer ergänzt")
    func fillsOnlyMissingFinalEnd() throws {
        let text = "[CHAPTER]\nSTART=0\nEND=5000\n[CHAPTER]\nSTART=5000\n"
        let chapters = FFMetadata.decodeChapters(text)
        let resolved = try #require(FFMetadata.normalizedChapters(chapters, totalDuration: 9))
        #expect(resolved.last?.end == 9)

        for end in ["5000", "4000", "ungueltig"] {
            let badChapters = FFMetadata.decodeChapters(text + "END=\(end)\n")
            #expect(FFMetadata.normalizedChapters(badChapters, totalDuration: 9) == nil)
        }
    }

    @Test("TIMEBASE wird korrekt skaliert")
    func scalesTimebase() {
        // Bei TIMEBASE=1/1 sind die Rohwerte bereits Sekunden.
        let text = """
        [CHAPTER]
        TIMEBASE=1/1
        START=5
        END=15
        title=Sekunden
        """
        let chapters = FFMetadata.decodeChapters(text)
        #expect(chapters.count == 1)
        #expect(chapters[0].start == 5)
        #expect(chapters[0].end == 15)
    }

    @Test("TIMEBASE wird vom vorherigen Kapitel geerbt")
    func inheritsTimebase() {
        // Handgepflegte Dateien wiederholen TIMEBASE oft nicht je Block.
        let text = """
        [CHAPTER]
        TIMEBASE=1/1000
        START=0
        END=1000
        title=Eins
        [CHAPTER]
        START=1000
        END=2000
        title=Zwei
        """
        let chapters = FFMetadata.decodeChapters(text)
        #expect(chapters.count == 2)
        #expect(chapters[1].start == 1)
        #expect(chapters[1].end == 2)
    }

    @Test("Fehlendes END wird aus dem Folgekapitel abgeleitet")
    func fillsMissingEnd() {
        // Ohne das entstünde ein stilles Kapitel mit Dauer 0.
        let text = """
        [CHAPTER]
        TIMEBASE=1/1000
        START=0
        title=Ohne Ende
        [CHAPTER]
        TIMEBASE=1/1000
        START=5000
        END=9000
        title=Zwei
        """
        let chapters = FFMetadata.decodeChapters(text)
        #expect(chapters.count == 2)
        #expect(chapters[0].end == 5)
    }

    @Test("Escapte Titel werden zurückverwandelt")
    func unescapesTitle() {
        let text = """
        [CHAPTER]
        TIMEBASE=1/1000
        START=0
        END=1000
        title=A\\=B\\;C
        """
        let chapters = FFMetadata.decodeChapters(text)
        #expect(chapters.count == 1)
        #expect(chapters[0].title == "A=B;C")
    }

    @Test("Leerer Text ergibt keine Kapitel")
    func emptyText() {
        #expect(FFMetadata.decodeChapters("").isEmpty)
    }

    @Test("Text ohne [CHAPTER] ergibt keine Kapitel")
    func noChapterBlocks() {
        #expect(FFMetadata.decodeChapters(";FFMETADATA1\ntitle=Buch\n").isEmpty)
    }

    @Test("Kaputte Pflichtwerte werden nicht als plausible Nullwerte übernommen")
    func malformedRequiredValuesStayInvalid() {
        let malformedStart = FFMetadata.decodeChapters("""
        [CHAPTER]
        TIMEBASE=1/1000
        START=keine-zahl
        END=10000
        title=Kaputt
        """)
        let malformedEnd = FFMetadata.decodeChapters("""
        [CHAPTER]
        TIMEBASE=1/1000
        START=0
        END=keine-zahl
        title=Kaputt
        """)
        let malformedTimebase = FFMetadata.decodeChapters("""
        [CHAPTER]
        TIMEBASE=1/0
        START=0
        END=10000
        title=Kaputt
        """)

        #expect(!FFMetadata.chaptersAreValid(malformedStart, totalDuration: 10))
        #expect(!FFMetadata.chaptersAreValid(malformedEnd, totalDuration: 10))
        #expect(!FFMetadata.chaptersAreValid(malformedTimebase, totalDuration: 10))
    }

    @Test("Der ffmetadata-Leser behält nie Daten oberhalb seiner Grenze")
    func boundedMetadataReader() {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(repeating: 0x41, count: 9))
        pipe.fileHandleForWriting.closeFile()
        var limitCallbackCount = 0

        let output = AudioFile.readAnalysisOutput(
            from: pipe.fileHandleForReading,
            maximumByteCount: 8,
            onAbort: { limitCallbackCount += 1 }
        )

        #expect(output.exceededLimit)
        #expect(!output.timedOut)
        #expect(!output.readFailed)
        #expect(output.data.isEmpty)
        #expect(limitCallbackCount == 1)
    }

    @Test("Der ffmetadata-Leser beendet eine offene Pipe nach seiner Frist")
    func metadataReaderTimesOut() {
        let pipe = Pipe()
        var abortCallbackCount = 0

        let output = AudioFile.readAnalysisOutput(
            from: pipe.fileHandleForReading,
            maximumByteCount: 8,
            timeout: 0.01,
            onAbort: { abortCallbackCount += 1 }
        )
        pipe.fileHandleForWriting.closeFile()

        #expect(output.timedOut)
        #expect(!output.exceededLimit)
        #expect(!output.readFailed)
        #expect(output.data.isEmpty)
        #expect(abortCallbackCount == 1)
    }

    @Test("EOF ersetzt die Frist für den Prozessabschluss nicht")
    func processExitHasDeadline() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        #expect(!AudioFile.waitForProcessExit(process, timeout: 0.01))
        ProcessTerminator.terminateAndWait([process], graceInterval: 0.01)
        process.waitUntilExit()
        #expect(!process.isRunning)
    }
}

@Suite("FFMetadata-Kapitelgrenzen")
struct ChapterValidationTests {
    @Test("Nur lückenlose Kapitel über die vollständige Dateidauer sind gültig")
    func validatesChapterRanges() {
        let valid = [
            FFMetadata.Chapter(start: 0, end: 10, title: "Eins"),
            FFMetadata.Chapter(start: 10, end: 20, title: "Zwei")
        ]
        #expect(FFMetadata.chaptersAreValid(valid, totalDuration: 20))
        #expect(!FFMetadata.chaptersAreValid([
            FFMetadata.Chapter(start: 0, end: 0, title: "Leer")
        ], totalDuration: 20))
        #expect(!FFMetadata.chaptersAreValid([
            FFMetadata.Chapter(start: 0, end: 10, title: "Eins"),
            FFMetadata.Chapter(start: 9, end: 20, title: "Überlappt")
        ], totalDuration: 20))
        #expect(!FFMetadata.chaptersAreValid([
            FFMetadata.Chapter(start: .nan, end: 10, title: "Ungültig")
        ], totalDuration: 20))
        #expect(!FFMetadata.chaptersAreValid([
            FFMetadata.Chapter(start: 1, end: 10, title: "Vorlauf fehlt"),
            FFMetadata.Chapter(start: 10, end: 20, title: "Zwei")
        ], totalDuration: 20))
        #expect(!FFMetadata.chaptersAreValid([
            FFMetadata.Chapter(start: 0, end: 9, title: "Eins"),
            FFMetadata.Chapter(start: 10, end: 20, title: "Lücke")
        ], totalDuration: 20))
        #expect(!FFMetadata.chaptersAreValid(valid, totalDuration: 25))
        #expect(!FFMetadata.chaptersAreValid(valid, totalDuration: 19))
        #expect(!FFMetadata.chaptersAreValid([
            FFMetadata.Chapter(start: 0, end: 20.1, title: "Eins"),
            FFMetadata.Chapter(start: 20.1, end: 20.2, title: "Nach Dateiende")
        ], totalDuration: 20))
        #expect(!FFMetadata.chaptersAreValid([
            FFMetadata.Chapter(start: 0, end: 20.1, title: "Eins"),
            FFMetadata.Chapter(start: 19.9, end: 20.2, title: "Würde beim Runden invertiert")
        ], totalDuration: 20))
    }
}
