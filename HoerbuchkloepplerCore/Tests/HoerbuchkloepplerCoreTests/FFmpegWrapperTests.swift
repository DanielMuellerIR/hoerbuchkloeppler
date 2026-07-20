import Testing
@testable import HoerbuchkloepplerCore
import Foundation

// Diese Tests decken die reine Kernlogik ab — also alles, was ohne echte
// Audiodateien, ohne ffmpeg-Prozess und ohne Oberfläche prüfbar ist:
// FFMETADATA-Escaping/Parsing, Kapitel-Arithmetik, Auto-Split, Zeit-Parsing.
//
// Bewusst NICHT hier: der ffmpeg-Aufruf selbst und das Encoding-Ergebnis.
// Dafür gibt es das End-to-End-Rezept in docs/build-and-test.md.

// MARK: - A) escapeFFMetadata — Sonderzeichen entwerten

@Suite("FFmpegWrapper – escapeFFMetadata")
struct EscapeFFMetadataTests {

    @Test("Gleichheitszeichen wird escaped")
    func escapesEqualsSign() {
        // "=" trennt im FFMETADATA1-Format Schlüssel von Wert.
        #expect(FFmpegWrapper.escapeFFMetadata("a=b") == "a\\=b")
    }

    @Test("Semikolon wird escaped")
    func escapesSemicolon() {
        // ";" leitet einen Kommentar ein — unescaped würde der Rest verschluckt.
        #expect(FFmpegWrapper.escapeFFMetadata("a;b") == "a\\;b")
    }

    @Test("Raute wird escaped")
    func escapesHash() {
        // "#" leitet ebenfalls einen Kommentar ein.
        #expect(FFmpegWrapper.escapeFFMetadata("a#b") == "a\\#b")
    }

    @Test("Backslash in der Mitte wird verdoppelt")
    func escapesBackslash() {
        #expect(FFmpegWrapper.escapeFFMetadata("a\\b") == "a\\\\b")
    }

    @Test("Zeilenumbruch wird zu Leerzeichen, nicht escaped")
    func newlineBecomesSpace() {
        // Ein Kapiteltitel ist einzeilig. Ein echter Umbruch — auch ein escapeter —
        // würde die chapters.txt zerreißen, deshalb wird er ersetzt statt maskiert.
        #expect(FFmpegWrapper.escapeFFMetadata("a\nb") == "a b")
        #expect(FFmpegWrapper.escapeFFMetadata("a\rb") == "a b")
    }

    @Test("Backslash am Ende wird entfernt")
    func trailingBackslashDropped() {
        // ffmpeg liest JEDEN Backslash am Zeilenende als Zeilenfortsetzung — auch
        // den maskierten. Bliebe er stehen, würde die folgende [CHAPTER]-Zeile
        // verschluckt und ein Kapitel ginge verloren.
        #expect(FFmpegWrapper.escapeFFMetadata("Titel\\") == "Titel")
        #expect(FFmpegWrapper.escapeFFMetadata("Titel\\\\") == "Titel")
    }

    @Test("Normaler Text bleibt unverändert")
    func normalTextUnchanged() {
        let normal = "Hörspiel Band 1"
        #expect(FFmpegWrapper.escapeFFMetadata(normal) == normal)
    }

    @Test("Mehrere Sonderzeichen werden alle escaped")
    func multipleSonderzeichen() {
        #expect(FFmpegWrapper.escapeFFMetadata("Titel=Wert;#") == "Titel\\=Wert\\;\\#")
    }
}

// MARK: - B) Round-Trip Escape ↔ Unescape

@Suite("Round-Trip Escape ↔ Unescape")
struct RoundTripTests {

    @Test("Normaler Text überlebt Round-Trip")
    func roundTripNormalText() {
        let original = "Kapitel 1 – Der Anfang"
        let back = AudioFile.unescapeFFMetadata(FFmpegWrapper.escapeFFMetadata(original))
        #expect(back == original)
    }

    @Test("Sonderzeichen überleben Round-Trip")
    func roundTripSonderzeichen() {
        let original = "Titel=Wert;#Kommentar"
        let back = AudioFile.unescapeFFMetadata(FFmpegWrapper.escapeFFMetadata(original))
        #expect(back == original)
    }

    @Test("Backslash in der Mitte überlebt Round-Trip")
    func roundTripInnerBackslash() {
        let original = "Pfad\\Datei"
        let back = AudioFile.unescapeFFMetadata(FFmpegWrapper.escapeFFMetadata(original))
        #expect(back == original)
    }

    @Test("Backslash am Ende überlebt den Round-Trip NICHT — bewusst")
    func roundTripTrailingBackslashIsLossy() {
        // Dokumentiert eine akzeptierte Verlustigkeit: ffmpeg kann einen
        // abschließenden Backslash ohnehin nicht verlustfrei zurücklesen.
        // Der Test hält fest, dass das Absicht ist und nicht versehentlich kippt.
        let back = AudioFile.unescapeFFMetadata(FFmpegWrapper.escapeFFMetadata("Titel\\"))
        #expect(back == "Titel")
    }
}

// MARK: - C) buildChapterMetadata — Kapitelgrenzen

@Suite("FFmpegWrapper – buildChapterMetadata")
struct BuildChapterMetadataTests {

    private func file(_ title: String, _ duration: TimeInterval) -> AudioFile {
        AudioFile(url: URL(fileURLWithPath: "/tmp/\(title).mp3"), startTime: 0, duration: duration, chapterTitle: title)
    }

    @Test("Leere Gruppe ergibt nur den Header")
    func emptyGroup() {
        #expect(FFmpegWrapper.buildChapterMetadata(group: []) == ";FFMETADATA1\n")
    }

    @Test("Ein Kapitel bekommt START=0 und END=Dauer in Millisekunden")
    func singleChapter() {
        let meta = FFmpegWrapper.buildChapterMetadata(group: [file("Kapitel 1", 10)])
        #expect(meta.contains("START=0\n"))
        #expect(meta.contains("END=10000\n"))
        #expect(meta.contains("title=Kapitel 1\n"))
        #expect(meta.contains("TIMEBASE=1/1000"))
    }

    @Test("Kapitel liegen lückenlos hintereinander")
    func chaptersAreSequential() {
        // Zweites Kapitel muss exakt dort beginnen, wo das erste endet — sonst
        // entstehen Lücken oder Überlappungen in der Kapitelnavigation.
        let meta = FFmpegWrapper.buildChapterMetadata(group: [file("Eins", 10), file("Zwei", 5)])
        #expect(meta.contains("START=0\nEND=10000"))
        #expect(meta.contains("START=10000\nEND=15000"))
    }

    @Test("Kapiteltitel mit Sonderzeichen wird escaped")
    func titleIsEscaped() {
        let meta = FFmpegWrapper.buildChapterMetadata(group: [file("A=B;C", 1)])
        #expect(meta.contains("title=A\\=B\\;C"))
    }

    @Test("Kapitel mit Dauer 0 erzeugt START==END")
    func zeroDurationChapter() {
        // Hält das reale Verhalten fest: die Filterung solcher Dateien passiert
        // erst beim Kodieren, nicht hier.
        let meta = FFmpegWrapper.buildChapterMetadata(group: [file("Leer", 0)])
        #expect(meta.contains("START=0\nEND=0"))
    }
}

// MARK: - D) parseFFMetadataChapters — Kapitel aus ffmpeg-Ausgabe lesen

@Suite("AudioFile – parseFFMetadataChapters")
struct ParseFFMetadataChaptersTests {

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
        let chapters = AudioFile.parseFFMetadataChapters(text)
        #expect(chapters.count == 2)
        #expect(chapters[0].start == 0)
        #expect(chapters[0].end == 10)
        #expect(chapters[0].title == "Kapitel 1")
        #expect(chapters[1].start == 10)
        #expect(chapters[1].end == 20)
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
        let chapters = AudioFile.parseFFMetadataChapters(text)
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
        let chapters = AudioFile.parseFFMetadataChapters(text)
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
        let chapters = AudioFile.parseFFMetadataChapters(text)
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
        let chapters = AudioFile.parseFFMetadataChapters(text)
        #expect(chapters.count == 1)
        #expect(chapters[0].title == "A=B;C")
    }

    @Test("Leerer Text ergibt keine Kapitel")
    func emptyText() {
        #expect(AudioFile.parseFFMetadataChapters("").isEmpty)
    }

    @Test("Text ohne [CHAPTER] ergibt keine Kapitel")
    func noChapterBlocks() {
        #expect(AudioFile.parseFFMetadataChapters(";FFMETADATA1\ntitle=Buch\n").isEmpty)
    }
}

// MARK: - E) splitAudioFilesIfNeeded — Auto-Split langer Bücher

@Suite("FFmpegWrapper – splitAudioFilesIfNeeded")
struct SplitAudioFilesTests {

    private func file(_ hours: Double) -> AudioFile {
        AudioFile(url: URL(fileURLWithPath: "/tmp/a.mp3"), startTime: 0, duration: hours * 3600, chapterTitle: "x")
    }

    @Test("Ohne Maximaldauer bleibt alles eine Gruppe")
    func noMaxDuration() {
        let groups = FFmpegWrapper.splitAudioFilesIfNeeded([file(1), file(1)], maxDurationHours: nil)
        #expect(groups.count == 1)
        #expect(groups[0].count == 2)
    }

    @Test("Maximaldauer 0 bedeutet unbegrenzt")
    func zeroMeansUnlimited() {
        let groups = FFmpegWrapper.splitAudioFilesIfNeeded([file(1), file(1)], maxDurationHours: 0)
        #expect(groups.count == 1)
    }

    @Test("Wird die Maximaldauer überschritten, entsteht eine neue Gruppe")
    func splitsWhenExceeded() {
        // 3 x 4h bei max 10h -> [4h+4h], [4h]
        let groups = FFmpegWrapper.splitAudioFilesIfNeeded([file(4), file(4), file(4)], maxDurationHours: 10)
        #expect(groups.count == 2)
        #expect(groups[0].count == 2)
        #expect(groups[1].count == 1)
    }

    @Test("Passt genau auf die Grenze, bleibt es eine Gruppe")
    func exactFitStaysOneGroup() {
        let groups = FFmpegWrapper.splitAudioFilesIfNeeded([file(5), file(5)], maxDurationHours: 10)
        #expect(groups.count == 1)
    }

    @Test("Leere Liste: mit Maximaldauer null Gruppen, ohne eine leere Gruppe")
    func emptyListIsAsymmetric() {
        // Festgehaltenes Ist-Verhalten, bewusst asymmetrisch:
        //   maxDurationHours == nil -> [[]]  (eine leere Gruppe, via early return)
        //   maxDurationHours >  0   -> []    (keine Gruppe, da nur nicht-leere angehängt werden)
        //
        // Heute harmlos: convert() hat ein `guard !session.audioFiles.isEmpty`
        // davor, die Funktion sieht also nie eine leere Liste. Fiele das Guard
        // weg, liefe die Gruppen-Schleife in convert() null Mal durch und der
        // Lauf meldete Erfolg, ohne je eine Datei erzeugt zu haben. Dieser Test
        // schlägt an, falls sich eine der beiden Seiten unbemerkt ändert.
        #expect(FFmpegWrapper.splitAudioFilesIfNeeded([], maxDurationHours: 10).isEmpty)
        #expect(FFmpegWrapper.splitAudioFilesIfNeeded([], maxDurationHours: nil).count == 1)
    }
}

// MARK: - F) resolveOutputURL — Dateinamen bei Auto-Split

@Suite("FFmpegWrapper – resolveOutputURL")
struct ResolveOutputURLTests {

    private let base = URL(fileURLWithPath: "/tmp/Buch.m4b")

    @Test("Ohne Split bleibt der Name unverändert")
    func singleGroupUnchanged() {
        #expect(FFmpegWrapper.resolveOutputURL(base, groupIndex: 0, splitGroupsCount: 1) == base)
    }

    @Test("Mit Split werden -01, -02 angehängt")
    func splitGetsSuffix() {
        let first = FFmpegWrapper.resolveOutputURL(base, groupIndex: 0, splitGroupsCount: 3)
        let second = FFmpegWrapper.resolveOutputURL(base, groupIndex: 1, splitGroupsCount: 3)
        #expect(first.lastPathComponent == "Buch-01.m4b")
        #expect(second.lastPathComponent == "Buch-02.m4b")
    }

    @Test("Endung und Ordner bleiben erhalten")
    func keepsExtensionAndFolder() {
        let url = FFmpegWrapper.resolveOutputURL(base, groupIndex: 0, splitGroupsCount: 2)
        #expect(url.pathExtension == "m4b")
        #expect(url.deletingLastPathComponent().path == "/tmp")
    }
}

// MARK: - G) timeToSeconds — ffmpeg-Zeitangaben

@Suite("FFmpegWrapper – timeToSeconds")
struct TimeToSecondsTests {

    @Test("00:00:00 → 0 Sekunden")
    func zero() { #expect(FFmpegWrapper.timeToSeconds("00:00:00") == 0) }

    @Test("01:02:03 → 3723 Sekunden")
    func typical() { #expect(FFmpegWrapper.timeToSeconds("01:02:03") == 3723) }

    @Test("Nachkommastellen werden berücksichtigt")
    func fractional() { #expect(FFmpegWrapper.timeToSeconds("00:00:01.50") == 1.5) }

    @Test("Ungültiger String → nil")
    func invalid() { #expect(FFmpegWrapper.timeToSeconds("kaputt") == nil) }

    @Test("Leerer String → nil")
    func empty() { #expect(FFmpegWrapper.timeToSeconds("") == nil) }

    @Test("Zu wenige Teile → nil")
    func tooFewParts() { #expect(FFmpegWrapper.timeToSeconds("01:02") == nil) }
}

// MARK: - H) extractTimeFromFFmpeg — Fortschritt aus der ffmpeg-Ausgabe

@Suite("FFmpegWrapper – extractTimeFromFFmpeg")
struct ExtractTimeTests {

    @Test("Zeit aus typischer ffmpeg-Zeile extrahieren")
    func typicalLine() {
        let line = "size=    1024kB time=00:01:23.45 bitrate=  48.0kbits/s speed=  50x"
        #expect(FFmpegWrapper.extractTimeFromFFmpeg(line) == "00:01:23.45")
    }

    @Test("Zeile ohne time= → nil")
    func noTime() {
        #expect(FFmpegWrapper.extractTimeFromFFmpeg("frame= 100 fps=25") == nil)
    }

    @Test("Leerer String → nil")
    func empty() { #expect(FFmpegWrapper.extractTimeFromFFmpeg("") == nil) }
}

// MARK: - I) sanitizeDuration — Schutz gegen NaN/Infinity aus korrupten Dateien

@Suite("AudioFile – sanitizeDuration")
struct SanitizeDurationTests {

    @Test("NaN wird zu 0")
    func nanBecomesZero() {
        // CMTimeGetSeconds liefert bei unlesbaren Dateien NaN. Ungeklemmt würden
        // spätere Int(NaN)-Casts crashen.
        #expect(AudioFile.sanitizeDuration(.nan) == 0)
    }

    @Test("Unendlich wird zu 0")
    func infinityBecomesZero() {
        #expect(AudioFile.sanitizeDuration(.infinity) == 0)
        #expect(AudioFile.sanitizeDuration(-.infinity) == 0)
    }

    @Test("Negative Dauer wird zu 0")
    func negativeBecomesZero() {
        #expect(AudioFile.sanitizeDuration(-5) == 0)
    }

    @Test("Gültige Dauer bleibt unverändert")
    func validUnchanged() {
        #expect(AudioFile.sanitizeDuration(42.5) == 42.5)
        #expect(AudioFile.sanitizeDuration(0) == 0)
    }

    @Test("Initializer klemmt die Dauer an der Quelle")
    func initSanitizes() {
        let file = AudioFile(url: URL(fileURLWithPath: "/tmp/x.mp3"), startTime: .nan, duration: .nan, chapterTitle: "x")
        #expect(file.duration == 0)
        #expect(file.startTime == 0)
    }
}
