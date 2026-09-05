import Foundation

extension FFmpegWrapper {
    static func ffmpegTimeArgument(_ seconds: TimeInterval) -> String {
        String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            seconds
        )
    }

    static func getArgsForStandardSlicing(
        file: AudioFile,
        url: URL,
        settings: AudioSettings
    ) -> [String] {
        // Zwischen-WAV direkt auf die Ziel-Abtastrate slicen statt hart auf 44100.
        // Sonst würde z.B. bei Ziel 48000 zweimal resampelt (Quelle→44100 beim
        // Slicen, 44100→48000 beim finalen Encode) — unnötiger Qualitätsverlust.
        // Ebenso auf die Ziel-KANALZAHL slicen (nicht hart Stereo): unkomprimiertes
        // WAV ist der Temp-Treiber (Standard-Modus hält ALLE Slices gleichzeitig),
        // und für ein Mono-Hörbuch (Default) halbiert Mono-Slicing den Temp-Bedarf.
        // Der finale `-ac`-Downmix bleibt identisch, nur eben schon beim Slicen.
        return ["-nostdin", "-y", "-ss", ffmpegTimeArgument(file.startTime), "-t", ffmpegTimeArgument(file.duration), "-i", file.url.path, "-vn", "-acodec", "pcm_s16le", "-ar", "\(settings.sampleRate)", "-ac", settings.isMono ? "1" : "2", url.path]
    }

    static func getArgsForParallelEncoding(
        file: AudioFile,
        url: URL,
        settings: AudioSettings,
        gainDB: Double = 0
    ) -> [String] {
        return ["-nostdin", "-y", "-ss", ffmpegTimeArgument(file.startTime), "-t", ffmpegTimeArgument(file.duration), "-i", file.url.path, "-vn", "-c:a", "aac_at", "-aac_at_mode", "cvbr", "-b:a", settings.bitrate, "-ar", "\(settings.sampleRate)", "-ac", settings.isMono ? "1" : "2"] + loudnessFilterArguments(gainDB: gainDB) + [url.path]
    }

    static func loudnessFilterArguments(gainDB: Double) -> [String] {
        gainDB == 0 ? [] : ["-af", "volume=\(gainDB)dB"]
    }
}
