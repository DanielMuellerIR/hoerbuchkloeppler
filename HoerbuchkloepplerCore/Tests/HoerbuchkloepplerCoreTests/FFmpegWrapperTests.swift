import Testing
@testable import HoerbuchkloepplerCore
import Foundation
import CoreGraphics
import ImageIO
import Darwin

private func conversionTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FFmpegWrapperTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false
    )
    return url
}

private func writeExecutable(_ url: URL, _ source: String) throws {
    try source.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
    )
}

private func onePixelPNGData(channelValue: UInt8 = 255) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytes = [UInt8](repeating: channelValue, count: 4)
    let image = bytes.withUnsafeBytes { storage -> CGImage? in
        guard let context = CGContext(
            data: UnsafeMutableRawPointer(mutating: storage.baseAddress),
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return context.makeImage()
    }
    let cgImage = try #require(image)
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data,
        "public.png" as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, cgImage, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Suite("ConversionSession – Cover-Auswahl")
@MainActor
struct CoverSelectionTests {
    @Test("Manuell gewähltes Cover bleibt als unveränderlicher Inhalt erhalten")
    func selectedCoverKeepsContentSnapshot() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cover = directory.appendingPathComponent("cover.png")
        let original = try onePixelPNGData()
        let replacement = try onePixelPNGData(channelValue: 127)
        try original.write(to: cover)
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }

        #expect(session.selectCover(url: cover))
        try replacement.write(to: cover)

        #expect(session.coverPath == cover.path)
        #expect(session.embeddedCoverData == original)
        #expect(FFmpegWrapper.coverSnapshotForConversion(session) == original)
        #expect(FFmpegWrapper.coverSnapshotForConversion(session) != replacement)
        #expect(session.coverImage != nil)
    }
}

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

    @Test("Eingebettetes Artwork braucht ein dekodierbares Bild innerhalb der Größenobergrenze")
    func validatesEmbeddedArtwork() throws {
        let png = try onePixelPNGData()

        #expect(AudioFile.validatedEmbeddedArtworkData(png) == png)
        #expect(AudioFile.validatedEmbeddedArtworkData(Data("kein Bild".utf8)) == nil)
        #expect(AudioFile.validatedEmbeddedArtworkData(
            Data(count: FFmpegWrapper.maximumCoverByteCount + 1)
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

    @Test("Kaputte Pflichtwerte werden nicht als plausible Nullwerte übernommen")
    func malformedRequiredValuesStayInvalid() {
        let malformedStart = AudioFile.parseFFMetadataChapters("""
        [CHAPTER]
        TIMEBASE=1/1000
        START=keine-zahl
        END=10000
        title=Kaputt
        """)
        let malformedEnd = AudioFile.parseFFMetadataChapters("""
        [CHAPTER]
        TIMEBASE=1/1000
        START=0
        END=keine-zahl
        title=Kaputt
        """)
        let malformedTimebase = AudioFile.parseFFMetadataChapters("""
        [CHAPTER]
        TIMEBASE=1/0
        START=0
        END=10000
        title=Kaputt
        """)

        #expect(!AudioFile.chaptersAreValid(malformedStart, totalDuration: 10))
        #expect(!AudioFile.chaptersAreValid(malformedEnd, totalDuration: 10))
        #expect(!AudioFile.chaptersAreValid(malformedTimebase, totalDuration: 10))
    }

    @Test("Der ffmetadata-Leser behält nie Daten oberhalb seiner Grenze")
    func boundedMetadataReader() {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(repeating: 0x41, count: 9))
        pipe.fileHandleForWriting.closeFile()
        var limitCallbackCount = 0

        let output = AudioFile.readFFMetadata(
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

        let output = AudioFile.readFFMetadata(
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

// MARK: - H) Prozessausgabe und Fortschrittsgrenzen

@Suite("FFmpegWrapper – serieller Pipe-Leser")
struct ProcessPipeReaderTests {
    @Test("Ein nie gestarteter Reader wird ohne offene Group freigegeben")
    func unstartedReaderIsReleased() {
        weak var releasedReader: ProcessPipeReader?
        do {
            let reader = ProcessPipeReader(handle: Pipe().fileHandleForReading)
            releasedReader = reader
        }
        #expect(releasedReader == nil)
    }

    @Test("waitUntilEOF wartet auf einen noch laufenden Callback")
    func waitsForCallbackJoin() throws {
        let pipe = Pipe()
        let reader = ProcessPipeReader(handle: pipe.fileHandleForReading)
        let callbackStarted = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let waitFinished = DispatchSemaphore(value: 0)

        reader.start { _ in
            callbackStarted.signal()
            releaseCallback.wait()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("stderr".utf8))
        try pipe.fileHandleForWriting.close()
        #expect(callbackStarted.wait(timeout: .now() + 1) == .success)

        DispatchQueue.global().async {
            _ = reader.waitUntilEOF()
            waitFinished.signal()
        }
        let premature = waitFinished.wait(timeout: .now() + 0.05)
        releaseCallback.signal()
        #expect(premature == .timedOut)
        #expect(waitFinished.wait(timeout: .now() + 1) == .success)
    }

    @Test("Zeitwerte funktionieren über jede Chunk-Grenze und der neueste gewinnt")
    func parsesSplitAndLatestProgress() {
        let bytes = Data("frame=1 time=00:00:01.23 speed=1x".utf8)
        for split in 1..<bytes.count {
            let parser = FFmpegProgressParser()
            _ = parser.consume(Data(bytes[..<split]))
            #expect(parser.consume(Data(bytes[split...])) == 1.23)
        }

        let parser = FFmpegProgressParser()
        let newest = parser.consume(
            Data("time=00:00:01.00\rtime=00:00:02.50\r".utf8)
        )
        #expect(newest == 2.5)
    }

    @Test("Begrenzter Prozess eskaliert und Exit ungleich null bleibt sichtbar")
    func capturedProcessHonorsTimeoutAndStatus() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hanging = directory.appendingPathComponent("hanging")
        let failing = directory.appendingPathComponent("failing")
        try writeExecutable(hanging, "#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n")
        try writeExecutable(failing, "#!/bin/sh\nprintf 'diagnose'\nexit 3\n")

        let start = Date()
        let timed = FFmpegWrapper.runCapturedProcess(
            executableURL: hanging,
            arguments: [],
            timeout: 0.05
        )
        guard case .timedOut = timed else {
            Issue.record("Hängender Prozess lieferte nicht .timedOut")
            return
        }
        #expect(Date().timeIntervalSince(start) < 2)

        let failed = FFmpegWrapper.runCapturedProcess(
            executableURL: failing,
            arguments: [],
            // Dieser Teil prüft Exit-Code und Ausgabe, nicht eine knappe
            // Zeitgrenze. Im parallelen Gesamtlauf kann selbst der kurze
            // Prozess unter Last länger als eine Sekunde bis zum Exit brauchen.
            timeout: 5
        )
        guard case .completed(let status, let output) = failed else {
            Issue.record("Beendeter Prozess lieferte kein Ergebnis")
            return
        }
        #expect(status == 3)
        #expect(String(data: output, encoding: .utf8) == "diagnose")
    }

    @Test("Ein Kind mit geerbtem stdout blockiert den Pipe-Join nicht")
    func inheritedPipeDescriptorDoesNotHang() throws {
        let script = """
        import subprocess, sys
        child = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            stdout=sys.stdout,
            stderr=sys.stderr,
        )
        print(child.pid, flush=True)
        """
        let start = Date()
        let result = FFmpegWrapper.runCapturedProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script],
            timeout: 2
        )
        guard case .completed(let status, let output) = result,
              let text = String(data: output, encoding: .utf8),
              let childPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            Issue.record("Helferprozess lieferte PID und Exit-Status nicht")
            return
        }
        #expect(status == 0)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(Darwin.kill(childPID, 0) == -1 && errno == ESRCH)
    }
}

@Suite("FFmpegWrapper – Prozessgruppen-Besitz")
struct ProcessGroupOwnershipTests {
    @Test("Abbruch beendet Nachkommen auch nach Ende des direkten Prozesses")
    func cancellationWaitsForDescendantsAfterLeaderExit() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let childPIDFile = directory.appendingPathComponent("child.pid")
        let script = """
        import os, subprocess, sys, time
        child = subprocess.Popen(["/bin/sleep", "30"])
        with open(sys.argv[1], "w", encoding="utf-8") as handle:
            handle.write(str(child.pid))
            handle.flush()
            os.fsync(handle.fileno())
        time.sleep(0.2)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, childPIDFile.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let context = ConversionContext()

        #expect(try context.run(process))
        process.waitUntilExit()
        let childPID = try #require(
            pid_t(String(contentsOf: childPIDFile, encoding: .utf8))
        )
        defer {
            if Darwin.kill(childPID, 0) == 0 {
                _ = Darwin.kill(childPID, SIGKILL)
            }
            context.unregister(process)
        }
        #expect(!process.isRunning)
        #expect(Darwin.kill(childPID, 0) == 0)

        #expect(context.cancel())
        let cleanupFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            context.finishAfterCancellationCleanup { _ in }
            cleanupFinished.signal()
        }
        #expect(cleanupFinished.wait(timeout: .now() + 5) == .success)

        let childExitDeadline = Date().addingTimeInterval(2)
        while Darwin.kill(childPID, 0) == 0, Date() < childExitDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(Darwin.kill(childPID, 0) == -1 && errno == ESRCH)
    }
}

// MARK: - I) Ausgabe-, Eingabe- und Temp-Besitz

@Suite("FFmpegWrapper – Dateibesitz")
struct ConversionFileOwnershipTests {
    private func audio(_ url: URL, duration: TimeInterval = 1) -> AudioFile {
        AudioFile(
            url: url,
            startTime: 0,
            duration: duration,
            chapterTitle: url.lastPathComponent
        )
    }

    @Test("Synchroner Startfehler wird dem GUI-Aufrufer zurückgegeben")
    @MainActor
    func conversionStartReturnsPlanFailure() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("eingang.wav")
        let output = directory.appendingPathComponent("ausgabe.m4b")
        try Data("eingang".utf8).write(to: input)
        let file = audio(input)
        let plan = FFmpegWrapper.makeConversionPlan(
            files: [file],
            outputURL: output,
            maxDurationHours: nil
        )
        try Data("fremd".utf8).write(to: output)
        let session = ConversionSession(settings: AudioSettings())
        session.audioFiles = [file]
        session.logSink = { _ in }

        let result = FFmpegWrapper.convert(session: session, plan: plan)

        guard case .rejected(let message) = result else {
            Issue.record("Geänderter Zielplan wurde trotzdem gestartet")
            return
        }
        #expect(message.contains("seit der Bestätigung verändert"))
        #expect(!session.showOverlay)
        #expect(session.lastConversionSucceeded == false)
    }

    @Test("Ein nach der Planung angelegtes Ziel wird nicht überschrieben")
    func missingDestinationUsesExclusiveRename() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = directory.appendingPathComponent(".staged.m4b")
        let expected = FFmpegWrapper.captureSnapshot(of: final)
        try Data("fremd".utf8).write(to: final)
        try Data("neu".utf8).write(to: staged)

        #expect(throws: ConversionOutputError.self) {
            try FFmpegWrapper.commitStagedOutput(
                staged,
                to: final,
                expectedDestination: expected
            )
        }
        #expect(try String(contentsOf: final, encoding: .utf8) == "fremd")
        #expect(try String(contentsOf: staged, encoding: .utf8) == "neu")
    }

    @Test("Ein nach Bestätigung ausgetauschtes Ziel wird zurückbehalten")
    func changedDestinationIsNotReplaced() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = directory.appendingPathComponent(".staged.m4b")
        try Data("bestätigt".utf8).write(to: final)
        let expected = FFmpegWrapper.captureSnapshot(of: final)
        try FileManager.default.removeItem(at: final)
        try Data("inzwischen neu".utf8).write(to: final)
        try Data("Konvertierung".utf8).write(to: staged)

        #expect(throws: ConversionOutputError.self) {
            try FFmpegWrapper.commitStagedOutput(
                staged,
                to: final,
                expectedDestination: expected
            )
        }
        #expect(try String(contentsOf: final, encoding: .utf8) == "inzwischen neu")
        #expect(try String(contentsOf: staged, encoding: .utf8) == "Konvertierung")
    }

    @Test("Ein direkt vor dem Rename ausgetauschtes Staging wird zurückgerollt")
    func replacedStagingEntryIsNotCommitted() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = directory.appendingPathComponent(".staged.m4b")
        let replacement = directory.appendingPathComponent("fremd.m4b")
        try Data("bestätigtes Ziel".utf8).write(to: final)
        try Data("eigene Ausgabe".utf8).write(to: staged)
        try Data("fremder Ersatz".utf8).write(to: replacement)
        let expected = FFmpegWrapper.captureSnapshot(of: final)

        #expect(throws: ConversionOutputError.self) {
            try FFmpegWrapper.commitStagedOutput(
                staged,
                to: final,
                expectedDestination: expected,
                beforeRename: {
                    try? FileManager.default.removeItem(at: staged)
                    try? FileManager.default.moveItem(at: replacement, to: staged)
                }
            )
        }
        #expect(try String(contentsOf: final, encoding: .utf8) == "bestätigtes Ziel")
        #expect(try String(contentsOf: staged, encoding: .utf8) == "fremder Ersatz")
    }

    @Test("Ein vor dem Commit ausgetauschtes Staging wird nicht übernommen")
    func stagingOwnershipSpansCreationAndCommit() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = FFmpegWrapper.stagingOutputURL(for: final)
        try Data("bestätigtes Ziel".utf8).write(to: final)
        let expectedDestination = FFmpegWrapper.captureSnapshot(of: final)
        let ownership = try FFmpegWrapper.createOwnedStagingOutput(staged)
        try Data("eigene Ausgabe".utf8).write(to: staged)
        try FileManager.default.removeItem(at: staged)
        try Data("fremder Ersatz".utf8).write(to: staged)

        #expect(throws: ConversionOutputError.self) {
            try FFmpegWrapper.commitStagedOutput(
                staged,
                to: final,
                expectedDestination: expectedDestination,
                expectedStagingOwnership: ownership
            )
        }
        #expect(try String(contentsOf: final, encoding: .utf8) == "bestätigtes Ziel")
        #expect(try String(contentsOf: staged, encoding: .utf8) == "fremder Ersatz")
    }

    @Test("ffmpeg startet nicht mit einem ausgetauschten geschützten Staging-Pfad")
    @MainActor
    func protectedStagingIsRecheckedBeforeProcessStart() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let sentinel = directory.appendingPathComponent("wichtig.txt")
        try Data("nicht verändern".utf8).write(to: sentinel)
        let staging = try FFmpegWrapper.createProtectedStagingOutput(for: final)
        try FileManager.default.removeItem(at: staging.url)
        try FileManager.default.createSymbolicLink(
            at: staging.url,
            withDestinationURL: sentinel
        )
        let session = ConversionSession(settings: AudioSettings())
        let context = session.beginConversionRun()

        let succeeded = FFmpegWrapper.runFinalProcess(
            args: ["-version"],
            session: session,
            context: context,
            progressBase: 0,
            progressWeight: 1,
            phaseDuration: 1,
            logMessage: "Testlauf",
            pacmanTitle: "Test",
            stagingURL: staging.url,
            expectedStagingOwnership: staging.ownership
        )

        #expect(!succeeded)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "nicht verändern")
    }

    @Test("ffmpeg schreibt nach der Vorprüfung weiter auf den geöffneten Staging-Inode")
    @MainActor
    func finalProcessOutputIsBoundToDescriptor() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staging = try FFmpegWrapper.createProtectedStagingOutput(for: final)
        let protectedDirectory = try #require(
            staging.ownership.protectedDirectory
        )
        let parkedDirectory = directory.appendingPathComponent("geparktes-staging")
        let decoyDirectory = directory.appendingPathComponent("fremdes-ziel")
        try FileManager.default.createDirectory(
            at: decoyDirectory,
            withIntermediateDirectories: false
        )
        let decoy = decoyDirectory.appendingPathComponent("entry.m4b")
        try Data("nicht verändern".utf8).write(to: decoy)
        let session = ConversionSession(settings: AudioSettings())
        let context = session.beginConversionRun()
        var hookError: (any Error)?

        let succeeded = FFmpegWrapper.runFinalProcess(
            args: [
                "-nostdin", "-y", "-f", "lavfi", "-i",
                "sine=frequency=1000:duration=0.05",
                "-c:a", "aac", "-f", "ipod", "/dev/fd/0"
            ],
            session: session,
            context: context,
            progressBase: 0,
            progressWeight: 1,
            phaseDuration: 0.05,
            logMessage: "Testlauf",
            pacmanTitle: "Test",
            stagingURL: staging.url,
            expectedStagingOwnership: staging.ownership,
            stagingHandle: staging,
            beforeProcessStart: {
                do {
                    try FileManager.default.moveItem(
                        at: protectedDirectory,
                        to: parkedDirectory
                    )
                    try FileManager.default.createSymbolicLink(
                        at: protectedDirectory,
                        withDestinationURL: decoyDirectory
                    )
                } catch {
                    hookError = error
                }
            }
        )

        #expect(hookError == nil)
        #expect(succeeded)
        #expect(try String(contentsOf: decoy, encoding: .utf8) == "nicht verändern")
        #expect(FFmpegWrapper.regularFileSize(
            parkedDirectory.appendingPathComponent("entry.m4b")
        ) != nil)
    }

    @Test("Neue Ausgaben behalten allgemein lesbare Dateirechte")
    func committedOutputUsesExpectedPermissions() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = FFmpegWrapper.stagingOutputURL(for: final)
        let ownership = try FFmpegWrapper.createOwnedStagingOutput(staged)
        try Data("Ausgabe".utf8).write(to: staged)

        _ = try FFmpegWrapper.commitStagedOutput(
            staged,
            to: final,
            expectedDestination: .missing,
            expectedStagingOwnership: ownership
        )

        let identity = try #require(
            FFmpegWrapper.fileSystemIdentity(at: final, followSymlink: false)
        )
        #expect(identity.mode & mode_t(0o777) == mode_t(0o644))
    }

    @Test("Ein erfolgreicher geschützter Commit entfernt seinen Staging-Ordner")
    func protectedCommitRemovesStagingDirectory() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        try Data("alt".utf8).write(to: final)
        let expected = FFmpegWrapper.captureSnapshot(of: final)
        let staging = try FFmpegWrapper.createProtectedStagingOutput(for: final)
        try Data("neu".utf8).write(to: staging.url)
        let context = ConversionContext()
        context.registerStagedOutput(
            staging.url,
            ownership: staging.ownership
        )

        let removed = try FFmpegWrapper.commitStagedOutput(
            staging.url,
            to: final,
            expectedDestination: expected,
            expectedStagingOwnership: staging.ownership
        )
        #expect(removed)
        context.completeStagedOutput(staging.url)

        #expect(try String(contentsOf: final, encoding: .utf8) == "neu")
        #expect(!FileManager.default.fileExists(
            atPath: try #require(staging.ownership.protectedDirectory).path
        ))
    }

    @Test("Absturz nach dem Zieltausch hinterlässt einen bereinigbaren Staging-Ordner")
    func crashAfterSwapCanSweepDisplacedDestination() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deadOwner: pid_t = 987_654
        let final = directory.appendingPathComponent("Buch.m4b")
        try Data("alt".utf8).write(to: final)
        let expected = FFmpegWrapper.captureSnapshot(of: final)
        var staging: StagingOutputHandle? = try FFmpegWrapper
            .createProtectedStagingOutput(for: final, ownerPID: deadOwner)
        let stagingURL = try #require(staging?.url)
        let ownership = try #require(staging?.ownership)
        let protectedDirectory = try #require(ownership.protectedDirectory)
        try Data("neu".utf8).write(to: stagingURL)

        let removed = try FFmpegWrapper.commitStagedOutput(
            stagingURL,
            to: final,
            expectedDestination: expected,
            expectedStagingOwnership: ownership,
            unlinkDisplacedOutput: { _, _ in false }
        )
        #expect(!removed)
        #expect(try String(contentsOf: final, encoding: .utf8) == "neu")
        #expect(try String(contentsOf: stagingURL, encoding: .utf8) == "alt")
        staging = nil

        FFmpegWrapper.cleanupOutputQuarantines(in: directory)

        #expect(!FileManager.default.fileExists(atPath: protectedDirectory.path))
        #expect(try String(contentsOf: final, encoding: .utf8) == "neu")
    }

    @Test("Fehlgeschlagenes Staging-Cleanup bleibt bis zum erneuten Versuch registriert")
    func residualProtectedStagingCleanupIsRetried() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staging = try FFmpegWrapper.createProtectedStagingOutput(for: final)
        let protectedDirectory = try #require(
            staging.ownership.protectedDirectory
        )
        try Data("unvollständig".utf8).write(to: staging.url)
        let recovery = protectedDirectory.appendingPathComponent("recovery.txt")
        try Data("behalten".utf8).write(to: recovery)
        let context = ConversionContext()
        context.registerStagedOutput(
            staging.url,
            ownership: staging.ownership
        )

        context.discardStagedOutput(staging.url)

        #expect(FileManager.default.fileExists(atPath: staging.url.path))
        #expect(FileManager.default.fileExists(atPath: recovery.path))
        try FileManager.default.removeItem(at: recovery)
        context.cleanupResidualStagedOutputs()

        #expect(!FileManager.default.fileExists(atPath: protectedDirectory.path))
    }

    @Test("Fehlgeschlagener Container-Cleanup nach Commit wird erneut versucht")
    func committedProtectedContainerCleanupIsRetried() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staging = try FFmpegWrapper.createProtectedStagingOutput(for: final)
        let protectedDirectory = try #require(
            staging.ownership.protectedDirectory
        )
        try Data("fertig".utf8).write(to: staging.url)
        let recovery = protectedDirectory.appendingPathComponent("recovery.txt")
        try Data("behalten".utf8).write(to: recovery)
        let context = ConversionContext()
        context.registerStagedOutput(
            staging.url,
            ownership: staging.ownership
        )
        _ = try FFmpegWrapper.commitStagedOutput(
            staging.url,
            to: final,
            expectedDestination: .missing,
            expectedStagingOwnership: staging.ownership
        )

        context.completeStagedOutput(staging.url)

        #expect(FileManager.default.fileExists(atPath: protectedDirectory.path))
        #expect(FileManager.default.fileExists(atPath: recovery.path))
        try FileManager.default.removeItem(at: recovery)
        context.cleanupResidualStagedOutputs()

        #expect(!FileManager.default.fileExists(atPath: protectedDirectory.path))
        #expect(try String(contentsOf: final, encoding: .utf8) == "fertig")
    }

    @Test("Altdatei-Cleanup liegt neben statt innerhalb des Staging-Ordners")
    func displacedCleanupUsesOutputParent() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staging = try FFmpegWrapper.createProtectedStagingOutput(for: final)
        let protectedDirectory = try #require(
            staging.ownership.protectedDirectory
        )
        try Data("alte Ausgabe".utf8).write(to: staging.url)
        let identity = try #require(
            FFmpegWrapper.fileSystemIdentity(
                at: staging.url,
                followSymlink: false
            )
        )
        var observedCleanupDirectory: URL?

        _ = FFmpegWrapper.removeDisplacedOutput(
            staging.url,
            expectedIdentity: identity,
            cleanupParent: directory,
            afterQuarantine: { cleanupDirectory in
                observedCleanupDirectory = cleanupDirectory
                try? Data("Recovery".utf8).write(
                    to: cleanupDirectory.appendingPathComponent("extra.txt")
                )
            }
        )

        #expect(
            observedCleanupDirectory?.deletingLastPathComponent()
                .standardizedFileURL.path == directory.standardizedFileURL.path
        )
        let nestedNames = try FileManager.default.contentsOfDirectory(
            atPath: protectedDirectory.path
        )
        #expect(!nestedNames.contains { $0.hasPrefix(".HB_DisplacedCleanup_") })
        #expect(!nestedNames.contains { $0.hasPrefix(".HB_Cleanup_") })
    }

    @Test("Austausch nach der Cleanup-Prüfung löscht den fremden Eintrag nicht")
    func cleanupEntryReplacementAfterCheckIsPreserved() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = ProcessInfo.processInfo.processIdentifier
        let cleanup = directory.appendingPathComponent(
            ".HB_DisplacedCleanup_\(owner)-\(UUID().uuidString)"
        )
        try FFmpegWrapper.createOwnedTempDirectory(cleanup, ownerPID: owner)
        let entry = cleanup.appendingPathComponent("entry")
        try Data("erwartet".utf8).write(to: entry)
        let entryIdentity = try #require(
            FFmpegWrapper.fileSystemIdentity(at: entry, followSymlink: false)
        )
        try FFmpegWrapper.writeCleanupEntryIdentity(entryIdentity, in: cleanup)
        let directoryIdentity = try #require(
            FFmpegWrapper.fileSystemIdentity(at: cleanup, followSymlink: false)
        )
        let record = CleanupEntryRecord(
            identity: entryIdentity,
            filename: "entry",
            stableIdentityOnly: false
        )
        var replacementWritten = false

        FFmpegWrapper.removeOwnedTempDirectory(
            cleanup,
            expectedIdentity: directoryIdentity,
            expectedOwnerPID: owner,
            beforeRecordedEntryQuarantine: { descriptor in
                guard "entry".withCString({
                    Darwin.unlinkat(descriptor, $0, 0)
                }) == 0 else { return }
                let replacement = "entry".withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                        mode_t(0o600)
                    )
                }
                guard replacement >= 0 else { return }
                let payload = Data("fremd".utf8)
                replacementWritten = payload.withUnsafeBytes {
                    Darwin.write(replacement, $0.baseAddress, $0.count)
                        == $0.count
                }
                _ = Darwin.close(replacement)
            },
            expectedCleanupEntry: record
        )

        #expect(replacementWritten)
        let remains = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".HB_Cleanup_\(owner)-") }
        let remaining = try #require(remains.first)
        #expect(try String(
            contentsOf: remaining.appendingPathComponent("entry"),
            encoding: .utf8
        ) == "fremd")
    }

    @Test("Absturz nach der Entry-Quarantäne bleibt bereinigbar")
    func crashAfterEntryQuarantineIsSwept() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deadOwner: pid_t = 987_654
        let cleanup = directory.appendingPathComponent(
            ".HB_DisplacedCleanup_\(deadOwner)-\(UUID().uuidString)"
        )
        try FFmpegWrapper.createOwnedTempDirectory(
            cleanup,
            ownerPID: deadOwner
        )
        let entry = cleanup.appendingPathComponent("entry")
        try Data("Altdatei".utf8).write(to: entry)
        let identity = try #require(
            FFmpegWrapper.fileSystemIdentity(at: entry, followSymlink: false)
        )
        try FFmpegWrapper.writeCleanupEntryIdentity(identity, in: cleanup)
        try FileManager.default.moveItem(
            at: entry,
            to: cleanup.appendingPathComponent(".HB_EntryCleanup")
        )

        FFmpegWrapper.cleanupOutputQuarantines(in: directory)

        #expect(!FileManager.default.fileExists(atPath: cleanup.path))
    }

    @Test("Verdrängte Altdatei und geschützter Ordner werden gemeinsam nachbereinigt")
    func protectedDisplacedOutputRetainsContainerUntilRetry() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        try Data("alt".utf8).write(to: final)
        let expected = FFmpegWrapper.captureSnapshot(of: final)
        let staging = try FFmpegWrapper.createProtectedStagingOutput(for: final)
        try Data("neu".utf8).write(to: staging.url)
        let context = ConversionContext()
        context.registerStagedOutput(
            staging.url,
            ownership: staging.ownership
        )

        let removed = try FFmpegWrapper.commitStagedOutput(
            staging.url,
            to: final,
            expectedDestination: expected,
            expectedStagingOwnership: staging.ownership,
            unlinkDisplacedOutput: { _, _ in false }
        )
        #expect(!removed)
        guard case .existing(let oldIdentity) = expected else {
            Issue.record("Bestehendes Ziel lieferte keinen Snapshot")
            return
        }
        context.registerDisplacedOutput(
            staging.url,
            expectedIdentity: oldIdentity
        )
        let protectedDirectory = try #require(
            staging.ownership.protectedDirectory
        )
        #expect(FileManager.default.fileExists(atPath: protectedDirectory.path))

        context.cleanupResidualStagedOutputs()

        #expect(!FileManager.default.fileExists(atPath: protectedDirectory.path))
        #expect(try String(contentsOf: final, encoding: .utf8) == "neu")
    }

    @Test("Abbruch registriert fehlgeschlagenes Altdatei-Cleanup erneut")
    func cancellationRetriesDisplacedOutputCleanup() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        try Data("alt".utf8).write(to: final)
        let expected = FFmpegWrapper.captureSnapshot(of: final)
        guard case .existing(let oldIdentity) = expected else {
            Issue.record("Bestehendes Ziel lieferte keinen Snapshot")
            return
        }
        let staging = try FFmpegWrapper.createProtectedStagingOutput(for: final)
        let protectedDirectory = try #require(
            staging.ownership.protectedDirectory
        )
        try Data("neu".utf8).write(to: staging.url)
        let context = ConversionContext { _, _ in
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: protectedDirectory.path
            )
        }
        context.registerStagedOutput(
            staging.url,
            ownership: staging.ownership
        )
        _ = try FFmpegWrapper.commitStagedOutput(
            staging.url,
            to: final,
            expectedDestination: expected,
            expectedStagingOwnership: staging.ownership,
            unlinkDisplacedOutput: { _, _ in false }
        )
        context.registerDisplacedOutput(
            staging.url,
            expectedIdentity: oldIdentity,
            stagingOwnership: staging.ownership
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: protectedDirectory.path
        )

        #expect(context.cancel())
        context.finishAfterCancellationCleanup { _ in }
        context.cleanupResidualStagedOutputs()

        #expect(!FileManager.default.fileExists(atPath: protectedDirectory.path))
        #expect(try String(contentsOf: final, encoding: .utf8) == "neu")
    }

    @Test("Volumes ohne Extended Attributes nutzen den Inode-Laufzeitbesitz")
    func unsupportedStagingMarkerFallsBackToRuntimeIdentity() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = FFmpegWrapper.stagingOutputURL(
            for: directory.appendingPathComponent("Buch.m4b")
        )
        let ownership = try FFmpegWrapper.createOwnedStagingOutput(
            staged,
            setOwnershipMarker: { _, _ in
                errno = ENOTSUP
                return -1
            }
        )
        try Data("unvollständig".utf8).write(to: staged)
        let context = ConversionContext()
        context.registerStagedOutput(staged, ownership: ownership)

        #expect(!ownership.hasPersistentMarker)
        #expect(context.cancel())
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test("Fehler beim Markieren löscht keinen Ersatz am Staging-Pfad")
    func stagingMarkerFailurePreservesReplacement() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = FFmpegWrapper.stagingOutputURL(
            for: directory.appendingPathComponent("Buch.m4b")
        )
        let movedCreation = directory.appendingPathComponent("eigener-inode.m4b")
        var hookError: (any Error)?

        #expect(throws: POSIXError.self) {
            try FFmpegWrapper.createOwnedStagingOutput(
                staged,
                setOwnershipMarker: { _, _ in
                    do {
                        try FileManager.default.moveItem(
                            at: staged,
                            to: movedCreation
                        )
                        try Data("fremder Ersatz".utf8).write(to: staged)
                    } catch {
                        hookError = error
                    }
                    errno = EPERM
                    return -1
                }
            )
        }

        #expect(hookError == nil)
        #expect(try String(contentsOf: staged, encoding: .utf8) == "fremder Ersatz")
        #expect(FileManager.default.fileExists(atPath: movedCreation.path))
    }

    @Test("Der Produktions-Catch löscht ein zurückgerolltes fremdes Staging nicht")
    func stagingRaceCatchPreservesReplacement() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = FFmpegWrapper.stagingOutputURL(for: final)
        let replacement = directory.appendingPathComponent("fremd.m4b")
        try Data("bestätigtes Ziel".utf8).write(to: final)
        try FFmpegWrapper.createOwnedStagingOutput(staged)
        try Data("eigene Ausgabe".utf8).write(to: staged)
        try Data("fremder Ersatz".utf8).write(to: replacement)
        let expected = FFmpegWrapper.captureSnapshot(of: final)
        let context = ConversionContext()
        context.registerStagedOutput(staged)

        do {
            _ = try FFmpegWrapper.commitStagedOutput(
                staged,
                to: final,
                expectedDestination: expected,
                beforeRename: {
                    try? FileManager.default.removeItem(at: staged)
                    try? FileManager.default.moveItem(at: replacement, to: staged)
                }
            )
            Issue.record("Staging-Austausch blieb unentdeckt")
        } catch {
            context.handleCommitFailure(error, stagedURL: staged)
        }

        #expect(try String(contentsOf: final, encoding: .utf8) == "bestätigtes Ziel")
        #expect(try String(contentsOf: staged, encoding: .utf8) == "fremder Ersatz")
    }

    @Test("Rollback-Fehler rettet die verdrängte Datei außerhalb der Altlastenbereinigung")
    func failedRollbackUsesRecoveryName() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = FFmpegWrapper.stagingOutputURL(for: final)
        let replacement = directory.appendingPathComponent("fremd.m4b")
        try Data("bestätigtes Ziel".utf8).write(to: final)
        try Data("eigene Ausgabe".utf8).write(to: staged)
        try Data("fremder Ersatz".utf8).write(to: replacement)
        let expected = FFmpegWrapper.captureSnapshot(of: final)
        var renameCount = 0
        var recoveryURL: URL?

        do {
            _ = try FFmpegWrapper.commitStagedOutput(
                staged,
                to: final,
                expectedDestination: expected,
                beforeRename: {
                    try? FileManager.default.removeItem(at: staged)
                    try? FileManager.default.moveItem(at: replacement, to: staged)
                },
                renameOperation: { source, destination, flags in
                    renameCount += 1
                    if renameCount == 2 {
                        errno = EIO
                        return -1
                    }
                    return FFmpegWrapper.renameEntry(
                        from: source,
                        to: destination,
                        flags: flags
                    )
                }
            )
            Issue.record("Erzwungener Rollback-Fehler blieb aus")
        } catch let error as ConversionOutputError {
            guard case .restoreFailed(_, let recovered, _) = error else {
                Issue.record("Unerwarteter Ausgabefehler: \(error)")
                return
            }
            recoveryURL = recovered
        }

        let recovered = try #require(recoveryURL)
        #expect(!recovered.lastPathComponent.contains(".partial-"))
        #expect(try String(contentsOf: final, encoding: .utf8) == "fremder Ersatz")
        #expect(try String(contentsOf: recovered, encoding: .utf8) == "bestätigtes Ziel")
        FFmpegWrapper.removeOrphanedStagedOutputs(for: final)
        #expect(FileManager.default.fileExists(atPath: recovered.path))
    }

    @Test("Auch ohne möglichen Recovery-Rename bleibt das alte Ziel geschützt")
    func failedRecoveryRenameRemainsProtectedFromOrphanCleanup() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = FFmpegWrapper.stagingOutputURL(for: final, ownerPID: 987_654)
        let replacement = directory.appendingPathComponent("fremd.m4b")
        try Data("bestätigtes Ziel".utf8).write(to: final)
        try Data("eigene Ausgabe".utf8).write(to: staged)
        try Data("fremder Ersatz".utf8).write(to: replacement)
        let expected = FFmpegWrapper.captureSnapshot(of: final)
        var renameCount = 0
        var reportedRecovery: URL?

        do {
            _ = try FFmpegWrapper.commitStagedOutput(
                staged,
                to: final,
                expectedDestination: expected,
                beforeRename: {
                    try? FileManager.default.removeItem(at: staged)
                    try? FileManager.default.moveItem(at: replacement, to: staged)
                },
                renameOperation: { source, destination, flags in
                    renameCount += 1
                    if renameCount >= 2 {
                        errno = EIO
                        return -1
                    }
                    return FFmpegWrapper.renameEntry(
                        from: source,
                        to: destination,
                        flags: flags
                    )
                }
            )
        } catch let error as ConversionOutputError {
            guard case .restoreFailed(_, let recovery, _) = error else {
                Issue.record("Unerwarteter Fehler: \(error)")
                return
            }
            reportedRecovery = recovery
        }

        #expect(reportedRecovery == staged)
        FFmpegWrapper.removeOrphanedStagedOutputs(for: final)
        #expect(try String(contentsOf: staged, encoding: .utf8) == "bestätigtes Ziel")
    }

    @Test("Fehlgeschlagener Altdatei-Unlink bleibt registriert und wird erneut versucht")
    func displacedOutputCleanupIsRetried() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let final = directory.appendingPathComponent("Buch.m4b")
        let staged = directory.appendingPathComponent(".staged.m4b")
        try Data("alt".utf8).write(to: final)
        try Data("neu".utf8).write(to: staged)
        let expected = FFmpegWrapper.captureSnapshot(of: final)
        let context = ConversionContext()
        context.registerStagedOutput(staged)

        let removed = try FFmpegWrapper.commitStagedOutput(
            staged,
            to: final,
            expectedDestination: expected,
            unlinkDisplacedOutput: { _, _ in false }
        )

        #expect(!removed)
        #expect(try String(contentsOf: final, encoding: .utf8) == "neu")
        #expect(try String(contentsOf: staged, encoding: .utf8) == "alt")
        guard case .existing(let displacedIdentity) = expected else {
            Issue.record("Bestehendes Ziel lieferte keinen Snapshot")
            return
        }
        context.registerDisplacedOutput(
            staged,
            expectedIdentity: displacedIdentity
        )
        context.cleanupResidualStagedOutputs()
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test("Bereinigung einer verdrängten Ausgabe löscht keinen späten Ersatz")
    func displacedOutputCleanupRechecksQuarantine() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let displaced = directory.appendingPathComponent(".partial.m4b")
        let parked = directory.appendingPathComponent("alt-gesichert.m4b")
        let replacement = directory.appendingPathComponent("fremd.m4b")
        try Data("bestätigte Altdatei".utf8).write(to: displaced)
        try Data("fremder Ersatz".utf8).write(to: replacement)
        let identity = try #require(
            FFmpegWrapper.fileSystemIdentity(at: displaced, followSymlink: false)
        )
        var hookError: (any Error)?

        let removed = FFmpegWrapper.removeDisplacedOutput(
            displaced,
            expectedIdentity: identity,
            beforeQuarantine: {
                do {
                    try FileManager.default.moveItem(at: displaced, to: parked)
                    try FileManager.default.moveItem(at: replacement, to: displaced)
                } catch {
                    hookError = error
                }
            }
        )

        #expect(hookError == nil)
        #expect(!removed)
        #expect(try String(contentsOf: displaced, encoding: .utf8) == "fremder Ersatz")
        #expect(try String(contentsOf: parked, encoding: .utf8) == "bestätigte Altdatei")
    }

    @Test("Ein Ersatz am Cleanup-Pfad wird bei verdrängten Ausgaben nicht gelöscht")
    func displacedCleanupIsBoundToOwnedDirectory() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let displaced = directory.appendingPathComponent("alt.m4b")
        let parked = directory.appendingPathComponent("cleanup-gesichert")
        try Data("bestätigte Altdatei".utf8).write(to: displaced)
        let identity = try #require(
            FFmpegWrapper.fileSystemIdentity(at: displaced, followSymlink: false)
        )
        var replacementPayload: URL?
        var hookError: (any Error)?

        let removed = FFmpegWrapper.removeDisplacedOutput(
            displaced,
            expectedIdentity: identity,
            afterQuarantine: { cleanupDirectory in
                do {
                    try FileManager.default.moveItem(
                        at: cleanupDirectory,
                        to: parked
                    )
                    try FileManager.default.createDirectory(
                        at: cleanupDirectory,
                        withIntermediateDirectories: false
                    )
                    let payload = cleanupDirectory.appendingPathComponent("wichtig.txt")
                    try Data("nicht anfassen".utf8).write(to: payload)
                    replacementPayload = payload
                } catch {
                    hookError = error
                }
            }
        )

        #expect(removed)
        #expect(hookError == nil)
        #expect(FileManager.default.fileExists(atPath: try #require(replacementPayload).path))
        #expect(FileManager.default.fileExists(atPath: parked.appendingPathComponent("entry").path))
    }

    @Test("Ein Ersatz innerhalb des Cleanup-Ordners bleibt erhalten")
    func cleanupRechecksEntryThroughBoundDirectory() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let displaced = directory.appendingPathComponent("alt.m4b")
        let parked = directory.appendingPathComponent("bestätigt-gesichert.m4b")
        try Data("bestätigte Altdatei".utf8).write(to: displaced)
        let identity = try #require(
            FFmpegWrapper.fileSystemIdentity(at: displaced, followSymlink: false)
        )
        var insertedEntry: URL?
        var hookError: (any Error)?

        let removed = FFmpegWrapper.removeDisplacedOutput(
            displaced,
            expectedIdentity: identity,
            afterQuarantine: { cleanupDirectory in
                do {
                    let entry = cleanupDirectory.appendingPathComponent("entry")
                    try FileManager.default.moveItem(at: entry, to: parked)
                    try Data("fremder Ersatz".utf8).write(to: entry)
                    insertedEntry = entry
                } catch {
                    hookError = error
                }
            }
        )

        #expect(removed)
        #expect(hookError == nil)
        #expect(try String(contentsOf: parked, encoding: .utf8) == "bestätigte Altdatei")
        let cleanupRests = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".HB_Cleanup_") }
        #expect(cleanupRests.count == 1)
        let preserved = try #require(cleanupRests.first)
            .appendingPathComponent(try #require(insertedEntry).lastPathComponent)
        #expect(try String(contentsOf: preserved, encoding: .utf8) == "fremder Ersatz")
    }

    @Test("Fehlgeschlagener Cleanup-Rollback rettet beide fremden Dateien")
    func failedCleanupRestoreUsesRecoveryName() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("alt.m4b")
        let expectedParked = directory.appendingPathComponent("erwartet-gesichert.m4b")
        let firstReplacement = directory.appendingPathComponent("fremd-eins.m4b")
        try Data("erwartete Datei".utf8).write(to: source)
        let expected = try #require(
            FFmpegWrapper.fileSystemIdentity(at: source, followSymlink: false)
        )
        try Data("fremd eins".utf8).write(to: firstReplacement)
        var hookError: (any Error)?

        let removed = FFmpegWrapper.removeDisplacedOutput(
            source,
            expectedIdentity: expected,
            beforeQuarantine: {
                do {
                    try FileManager.default.moveItem(at: source, to: expectedParked)
                    try FileManager.default.moveItem(at: firstReplacement, to: source)
                } catch {
                    hookError = error
                }
            },
            beforeRestore: {
                do {
                    try Data("fremd zwei".utf8).write(to: source)
                } catch {
                    hookError = error
                }
            }
        )

        #expect(!removed)
        #expect(hookError == nil)
        #expect(try String(contentsOf: source, encoding: .utf8) == "fremd zwei")
        #expect(try String(contentsOf: expectedParked, encoding: .utf8) == "erwartete Datei")
        let recoveryFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".recovery-") }
        #expect(recoveryFiles.count == 1)
        #expect(try String(contentsOf: try #require(recoveryFiles.first), encoding: .utf8) == "fremd eins")
    }

    @Test("Ein Ersatz am Cleanup-Pfad wird bei Staging-Ausgaben nicht gelöscht")
    func stagingCleanupIsBoundToOwnedDirectory() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = FFmpegWrapper.stagingOutputURL(
            for: directory.appendingPathComponent("Buch.m4b")
        )
        let parked = directory.appendingPathComponent("cleanup-gesichert")
        let ownership = try FFmpegWrapper.createOwnedStagingOutput(staged)
        try Data("unvollständig".utf8).write(to: staged)
        var replacementPayload: URL?
        var hookError: (any Error)?

        let removed = FFmpegWrapper.removeOwnedStagedOutput(
            staged,
            expectedOwnership: ownership,
            afterQuarantine: { cleanupDirectory in
                do {
                    try FileManager.default.moveItem(
                        at: cleanupDirectory,
                        to: parked
                    )
                    try FileManager.default.createDirectory(
                        at: cleanupDirectory,
                        withIntermediateDirectories: false
                    )
                    let payload = cleanupDirectory.appendingPathComponent("wichtig.txt")
                    try Data("nicht anfassen".utf8).write(to: payload)
                    replacementPayload = payload
                } catch {
                    hookError = error
                }
            }
        )

        #expect(removed)
        #expect(hookError == nil)
        #expect(FileManager.default.fileExists(atPath: try #require(replacementPayload).path))
        #expect(FileManager.default.fileExists(atPath: parked.appendingPathComponent("entry").path))
    }

    @Test("Verwaiste Ausgabe-Cleanup-Verzeichnisse werden nach einem Absturz entfernt")
    func orphanedOutputCleanupDirectoriesAreSwept() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deadOwner: pid_t = 987_654
        let stagingCleanup = directory.appendingPathComponent(
            ".HB_StagingCleanup_\(deadOwner)-\(UUID().uuidString)"
        )
        let displacedCleanup = directory.appendingPathComponent(
            ".HB_DisplacedCleanup_\(deadOwner)-\(UUID().uuidString)"
        )
        let reboundCleanup = directory.appendingPathComponent(
            ".HB_Cleanup_\(deadOwner)-\(UUID().uuidString)"
        )
        for cleanup in [stagingCleanup, displacedCleanup, reboundCleanup] {
            try FFmpegWrapper.createOwnedTempDirectory(
                cleanup,
                ownerPID: deadOwner
            )
            let entry = cleanup.appendingPathComponent("entry")
            try Data("Rest".utf8).write(to: entry)
            let identity = try #require(
                FFmpegWrapper.fileSystemIdentity(
                    at: entry,
                    followSymlink: false
                )
            )
            try FFmpegWrapper.writeCleanupEntryIdentity(
                identity,
                in: cleanup
            )
        }

        FFmpegWrapper.cleanupOutputQuarantines(in: directory)

        #expect(!FileManager.default.fileExists(atPath: stagingCleanup.path))
        #expect(!FileManager.default.fileExists(atPath: displacedCleanup.path))
        #expect(!FileManager.default.fileExists(atPath: reboundCleanup.path))
    }

    @Test("Absturz-Sweep erhält einen fremden Eintrag in der Cleanup-Quarantäne")
    func outputCleanupSweepRejectsMismatchedEntry() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deadOwner: pid_t = 987_654
        let cleanup = directory.appendingPathComponent(
            ".HB_DisplacedCleanup_\(deadOwner)-\(UUID().uuidString)"
        )
        try FFmpegWrapper.createOwnedTempDirectory(cleanup, ownerPID: deadOwner)
        let expectedSource = directory.appendingPathComponent("erwartet.m4b")
        try Data("erwartet".utf8).write(to: expectedSource)
        let expected = try #require(
            FFmpegWrapper.fileSystemIdentity(
                at: expectedSource,
                followSymlink: false
            )
        )
        try FFmpegWrapper.writeCleanupEntryIdentity(expected, in: cleanup)
        let entry = cleanup.appendingPathComponent("entry")
        try Data("fremder Eintrag".utf8).write(to: entry)

        FFmpegWrapper.cleanupOutputQuarantines(in: directory)

        #expect(FileManager.default.fileExists(atPath: cleanup.path))
        #expect(try String(contentsOf: entry, encoding: .utf8) == "fremder Eintrag")
    }

    @Test("Nur ein Lauf kann dasselbe Ziel reservieren")
    func outputLeaseIsExclusiveWithinProcess() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("Buch.m4b")
        var first: OutputLeaseSet? = try FFmpegWrapper.acquireOutputLeases(for: [output])
        _ = withExtendedLifetime(first) {
            #expect(throws: ConversionOutputError.self) {
                _ = try FFmpegWrapper.acquireOutputLeases(for: [output])
            }
        }
        first = nil
        _ = try FFmpegWrapper.acquireOutputLeases(for: [output])
    }

    @Test("Case-insensitive Zielschreibweisen teilen Lease und Lock-Datei")
    func caseInsensitiveLeaseKeysMatch() {
        let upper = URL(fileURLWithPath: "/tmp/Buch.m4b")
        let lower = URL(fileURLWithPath: "/tmp/buch.m4b")
        #expect(
            FFmpegWrapper.outputLeaseKey(
                for: upper,
                caseSensitiveNames: false
            ) == FFmpegWrapper.outputLeaseKey(
                for: lower,
                caseSensitiveNames: false
            )
        )
        #expect(
            FFmpegWrapper.outputLockURL(
                for: upper,
                caseSensitiveNames: false
            ).lastPathComponent == FFmpegWrapper.outputLockURL(
                for: lower,
                caseSensitiveNames: false
            ).lastPathComponent
        )
        #expect(
            FFmpegWrapper.outputLeaseKey(
                for: upper,
                caseSensitiveNames: true
            ) != FFmpegWrapper.outputLeaseKey(
                for: lower,
                caseSensitiveNames: true
            )
        )
    }

    @Test("Die Zielreservierung gilt auch gegenüber einem zweiten Prozess")
    func outputLeaseIsExclusiveAcrossProcesses() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("Buch.m4b")
        var lease: OutputLeaseSet? = try FFmpegWrapper.acquireOutputLeases(for: [output])
        let lockPath = FFmpegWrapper.outputLockURL(for: output).path
        let script = """
        import fcntl, sys
        handle = open(sys.argv[1], 'a')
        try:
            fcntl.lockf(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit(9)
        """

        let blocked = withExtendedLifetime(lease) {
            FFmpegWrapper.runCapturedProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", script, lockPath],
                timeout: 2
            )
        }
        guard case .completed(let blockedStatus, _) = blocked else {
            Issue.record("Zweiter Prozess lieferte keinen Exit-Status")
            return
        }
        #expect(blockedStatus == 9)

        lease = nil
        let available = FFmpegWrapper.runCapturedProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script, lockPath],
            timeout: 2
        )
        guard case .completed(let availableStatus, _) = available else {
            Issue.record("Zweiter Prozess lieferte nach Freigabe keinen Exit-Status")
            return
        }
        #expect(availableStatus == 0)
    }

    @Test("Split-Ausgabe darf keine physische Eingabe ersetzen")
    func splitOutputCannotAliasInput() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Buch-01.m4b")
        try Data("Original".utf8).write(to: source)
        let files = [audio(source, duration: 3_600), audio(source, duration: 3_600)]
        let plan = FFmpegWrapper.makeConversionPlan(
            files: files,
            outputURL: directory.appendingPathComponent("Buch.m4b"),
            maxDurationHours: 1
        )

        #expect(throws: ConversionOutputError.self) {
            try FFmpegWrapper.validateConversionPlan(plan)
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == "Original")
    }

    @Test("Hardlink-Ausgabe auf eine Eingabe wird erkannt")
    func hardLinkedOutputCannotAliasInput() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Quelle.m4b")
        let output = directory.appendingPathComponent("Ziel.m4b")
        try Data("Original".utf8).write(to: source)
        try FileManager.default.linkItem(at: source, to: output)
        let plan = FFmpegWrapper.makeConversionPlan(
            files: [audio(source)],
            outputURL: output,
            maxDurationHours: nil
        )

        #expect(throws: ConversionOutputError.self) {
            try FFmpegWrapper.validateConversionPlan(plan)
        }
    }

    @Test("Eine nach der Planung geänderte Quelle wird abgewiesen")
    func changedInputIsRejected() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Quelle.wav")
        try Data("alt".utf8).write(to: source)
        let plan = FFmpegWrapper.makeConversionPlan(
            files: [audio(source)],
            outputURL: directory.appendingPathComponent("Ziel.m4b"),
            maxDurationHours: nil
        )
        try Data("anderer und längerer Inhalt".utf8).write(to: source)

        #expect(throws: ConversionOutputError.self) {
            try FFmpegWrapper.validateConversionPlan(plan)
        }
    }

    @Test("Gebrochener Ziel-Symlink verlangt eine Überschreibbestätigung")
    func brokenOutputSymlinkRequiresConfirmation() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Quelle.wav")
        let output = directory.appendingPathComponent("Buch.m4b")
        try Data("audio".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(
            at: output,
            withDestinationURL: directory.appendingPathComponent("fehlt.m4b")
        )
        let plan = FFmpegWrapper.makeConversionPlan(
            files: [audio(source)],
            outputURL: output,
            maxDurationHours: nil
        )

        #expect(plan.outputURLsRequiringOverwriteConfirmation == [output])
    }

    @Test("Coverdaten bleiben nach Austausch der Quelldatei unverändert")
    func coverIsSnapshotted() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cover = directory.appendingPathComponent("cover.jpg")
        let original = try onePixelPNGData()
        try original.write(to: cover)
        let snapshot = try #require(FFmpegWrapper.loadCoverSnapshot(at: cover))
        try Data("nachher".utf8).write(to: cover)

        #expect(snapshot == original)
    }

    @Test("Cover-Lader weist FIFO, Übergröße und ungültige Bilddaten ab")
    func coverSnapshotRejectsUnsafeInputs() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("cover-fifo.jpg")
        let oversized = directory.appendingPathComponent("cover-gross.jpg")
        let invalid = directory.appendingPathComponent("cover-ungueltig.jpg")

        let fifoResult = fifo.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.mkfifo($0, mode_t(0o600)) } ?? -1
        }
        #expect(fifoResult == 0)
        let descriptor = oversized.withUnsafeFileSystemRepresentation { path in
            path.map {
                Darwin.open($0, O_CREAT | O_WRONLY | O_CLOEXEC, mode_t(0o600))
            } ?? -1
        }
        #expect(descriptor >= 0)
        if descriptor >= 0 {
            #expect(Darwin.ftruncate(
                descriptor,
                off_t(FFmpegWrapper.maximumCoverByteCount + 1)
            ) == 0)
            _ = Darwin.close(descriptor)
        }
        try Data("kein Bild".utf8).write(to: invalid)

        let start = Date()
        #expect(FFmpegWrapper.loadCoverSnapshot(at: fifo) == nil)
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(FFmpegWrapper.loadCoverSnapshot(at: oversized) == nil)
        #expect(FFmpegWrapper.loadCoverSnapshot(at: invalid) == nil)
    }

    @Test("Cover-Snapshot verlangt den beim Klick erfassten Dateieintrag")
    func coverSnapshotRejectsReplacementAfterPlanning() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cover = directory.appendingPathComponent("cover.png")
        let data = try onePixelPNGData()
        try data.write(to: cover)
        let expected = try #require(
            FFmpegWrapper.fileSystemIdentity(at: cover, followSymlink: true)
        )
        try FileManager.default.removeItem(at: cover)
        try data.write(to: cover)

        #expect(FFmpegWrapper.loadCoverSnapshot(
            at: cover,
            expectedIdentity: expected
        ) == nil)
    }

    @Test("Ohne geplante Cover-Identität wird eine später erschienene Datei nicht geladen")
    func plannedCoverRequiresCapturedIdentity() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cover = directory.appendingPathComponent("cover.png")
        let expected = FFmpegWrapper.fileSystemIdentity(
            at: cover,
            followSymlink: true
        )
        try onePixelPNGData().write(to: cover)

        #expect(FFmpegWrapper.loadPlannedCoverSnapshot(
            at: cover,
            expectedIdentity: expected
        ) == nil)
    }

    @Test("Ein bereits abgebrochener Cover-Snapshot berührt den Pfad nicht")
    func coverSnapshotStopsBeforeIOWhenCancelled() throws {
        let directory = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("cover-fifo.jpg")
        let fifoResult = fifo.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.mkfifo($0, mode_t(0o600)) } ?? -1
        }
        #expect(fifoResult == 0)

        let start = Date()
        #expect(FFmpegWrapper.loadCoverSnapshot(
            at: fifo,
            isCancelled: { true }
        ) == nil)
        #expect(Date().timeIntervalSince(start) < 0.1)
    }

    @Test("Vorbestehendes Temp-Verzeichnis wird nicht beansprucht")
    func tempCreationIsExclusive() throws {
        let root = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("HB_Temp_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let sentinel = directory.appendingPathComponent("wichtig.txt")
        try Data("behalten".utf8).write(to: sentinel)

        #expect(throws: (any Error).self) {
            try FFmpegWrapper.createOwnedTempDirectory(directory)
        }
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test("Ausgetauschte Temp-Verzeichnisse bleiben bei Abschluss und Abbruch erhalten")
    func replacedTempDirectoryIsNotRemoved() throws {
        let root = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for cancel in [false, true] {
            let directory = root.appendingPathComponent("HB_Temp_\(UUID().uuidString)")
            let parked = root.appendingPathComponent("ursprünglich-\(UUID().uuidString)")
            try FFmpegWrapper.createOwnedTempDirectory(directory)
            let context = ConversionContext()
            context.registerTempDirectory(directory)
            try FileManager.default.moveItem(at: directory, to: parked)
            try FFmpegWrapper.createOwnedTempDirectory(directory)
            let sentinel = directory.appendingPathComponent("wichtig.txt")
            try Data("behalten".utf8).write(to: sentinel)

            if cancel {
                context.cancel()
            } else {
                context.removeTempDirectory(directory)
            }

            #expect(FileManager.default.fileExists(atPath: sentinel.path))
            #expect(FileManager.default.fileExists(atPath: parked.path))
        }
    }

    @Test("Eigene Temp-Verzeichnisse werden trotz erzeugter Kinddateien entfernt")
    func populatedTempDirectoriesAreRemoved() throws {
        let root = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for cancel in [false, true] {
            let directory = root.appendingPathComponent("HB_Temp_\(UUID().uuidString)")
            try FFmpegWrapper.createOwnedTempDirectory(directory)
            let context = ConversionContext()
            context.registerTempDirectory(directory)
            try Data("Segment".utf8).write(
                to: directory.appendingPathComponent("seg_0.wav")
            )

            if cancel {
                context.cancel()
            } else {
                context.removeTempDirectory(directory)
            }

            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @Test("Temp-Cleanup rollt einen Austausch nach der Vorprüfung zurück")
    func tempCleanupRechecksQuarantinedEntry() throws {
        let root = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("HB_Temp_\(UUID().uuidString)")
        let parked = root.appendingPathComponent("ursprünglich")
        try FFmpegWrapper.createOwnedTempDirectory(directory)
        let identity = try #require(
            FFmpegWrapper.fileSystemIdentity(at: directory, followSymlink: false)
        )
        var hookError: (any Error)?

        FFmpegWrapper.removeOwnedTempDirectory(
            directory,
            expectedIdentity: identity,
            beforeQuarantine: {
                do {
                    try FileManager.default.moveItem(at: directory, to: parked)
                    try FFmpegWrapper.createOwnedTempDirectory(directory)
                    try Data("behalten".utf8).write(
                        to: directory.appendingPathComponent("wichtig.txt")
                    )
                } catch {
                    hookError = error
                }
            }
        )

        #expect(hookError == nil)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("wichtig.txt").path
        ))
        #expect(FileManager.default.fileExists(atPath: parked.path))
    }

    @Test("Temp-Cleanup bindet die rekursive Löschung an den geprüften Inode")
    func tempCleanupReopensQuarantineByIdentity() throws {
        let root = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("HB_Temp_\(UUID().uuidString)")
        let parked = root.appendingPathComponent("ursprüngliche-quarantaene")
        try FFmpegWrapper.createOwnedTempDirectory(directory)
        try Data("eigen".utf8).write(
            to: directory.appendingPathComponent("segment.m4a")
        )
        let identity = try #require(
            FFmpegWrapper.fileSystemIdentity(at: directory, followSymlink: false)
        )
        var replacementURL: URL?
        var hookError: (any Error)?

        FFmpegWrapper.removeOwnedTempDirectory(
            directory,
            expectedIdentity: identity,
            beforeBoundRemoval: {
                do {
                    let quarantine = try #require(
                        FileManager.default.contentsOfDirectory(
                            at: root,
                            includingPropertiesForKeys: nil
                        ).first { $0.lastPathComponent.hasPrefix(".HB_Cleanup_") }
                    )
                    try FileManager.default.moveItem(at: quarantine, to: parked)
                    try FileManager.default.createDirectory(
                        at: quarantine,
                        withIntermediateDirectories: false
                    )
                    try Data("behalten".utf8).write(
                        to: quarantine.appendingPathComponent("wichtig.txt")
                    )
                    replacementURL = quarantine
                } catch {
                    hookError = error
                }
            }
        )

        let replacement = try #require(replacementURL)
        #expect(hookError == nil)
        #expect(FileManager.default.fileExists(
            atPath: replacement.appendingPathComponent("wichtig.txt").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: parked.appendingPathComponent("segment.m4a").path
        ))
    }

    @Test("Altlastenbereinigung verlangt exakten Namen und gültigen Besitzer")
    func orphanCleanupRequiresOwnershipProof() throws {
        let root = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unowned = root.appendingPathComponent("HB_Temp_\(UUID().uuidString)")
        let orphan = root.appendingPathComponent("HB_Temp_\(UUID().uuidString)")
        let misleading = root.appendingPathComponent("HB_Temp_nicht-eine-uuid")
        for directory in [unowned, misleading] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        try FFmpegWrapper.createOwnedTempDirectory(orphan)
        try "987654".write(
            to: orphan.appendingPathComponent(".owner-pid"),
            atomically: true,
            encoding: .utf8
        )
        let old = Date(timeIntervalSince1970: 1)
        for directory in [unowned, orphan, misleading] {
            try FileManager.default.setAttributes(
                [.creationDate: old],
                ofItemAtPath: directory.path
            )
        }

        FFmpegWrapper.cleanupOldTempDirectories(
            in: root,
            now: Date(timeIntervalSince1970: 200_000)
        )

        #expect(FileManager.default.fileExists(atPath: unowned.path))
        #expect(FileManager.default.fileExists(atPath: misleading.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test("Altlastenbereinigung erfasst markierte Cleanup-Quarantänen")
    func orphanCleanupRemovesOwnedCleanupQuarantine() throws {
        let root = try conversionTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cleanup = root.appendingPathComponent(
            ".HB_Cleanup_987654-\(UUID().uuidString)"
        )
        let decoy = root.appendingPathComponent(
            ".HB_Cleanup_987654-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: cleanup, withIntermediateDirectories: false)
        try "987654".write(
            to: cleanup.appendingPathComponent(".owner-pid"),
            atomically: true,
            encoding: .utf8
        )
        try Data("rest".utf8).write(to: cleanup.appendingPathComponent("segment.m4a"))
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: false)
        let old = Date(timeIntervalSince1970: 1)
        for directory in [cleanup, decoy] {
            try FileManager.default.setAttributes(
                [.creationDate: old],
                ofItemAtPath: directory.path
            )
        }

        FFmpegWrapper.cleanupOldTempDirectories(
            in: root,
            now: Date(timeIntervalSince1970: 200_000)
        )

        #expect(!FileManager.default.fileExists(atPath: cleanup.path))
        #expect(FileManager.default.fileExists(atPath: decoy.path))
    }
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
