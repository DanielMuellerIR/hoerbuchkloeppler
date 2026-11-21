import Foundation
import Testing
@testable import HoerbuchkloepplerCore

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

@Suite("FFmpegWrapper – extractTimeFromFFmpeg")
struct ExtractTimeTests {

    @Test("Zeit aus typischer ffmpeg-Zeile extrahieren")
    func typicalLine() {
        let line = "size=    1024kB time=00:01:23.45 bitrate=  48.0kbits/s speed=  50x"
        #expect(FFmpegWrapper.extractTimeFromFFmpeg(line) == "00:01:23.45")
    }

    @Test("Die Fortschrittszeit überschreitet die 100-Stunden-Grenze")
    func progressBeyondTwoDigitHours() {
        var parser = FFmpegProgressParser()
        #expect(parser.consume(Data("size=N/A time=99:59:59.99\rtime=100:00".utf8)) == 359_999.99)
        #expect(parser.consume(Data(":00.05 bitrate=N/A\r".utf8)) == 360_000.05)
    }

    @Test("Zeile ohne time= → nil")
    func noTime() {
        #expect(FFmpegWrapper.extractTimeFromFFmpeg("frame= 100 fps=25") == nil)
    }

    @Test("Leerer String → nil")
    func empty() { #expect(FFmpegWrapper.extractTimeFromFFmpeg("") == nil) }
}
