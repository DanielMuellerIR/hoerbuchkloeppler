import Foundation

enum MuxAudioMode {
    case streamCopy
    case encodeAAC(settings: AudioSettings, gainDB: Double)

    var timestampArguments: [String] {
        switch self {
        case .streamCopy: ["-copyts"]
        case .encodeAAC: []
        }
    }

    var codecArguments: [String] {
        switch self {
        case .streamCopy:
            ["-c:a", "copy"]
        case let .encodeAAC(settings, gainDB):
            FFmpegWrapper.aacEncodingArguments(settings: settings, gainDB: gainDB)
        }
    }
}

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
        [
            "-nostdin", "-y", "-ss", ffmpegTimeArgument(file.startTime),
            "-t", ffmpegTimeArgument(file.duration), "-i", file.url.path, "-vn"
        ] + aacEncodingArguments(settings: settings, gainDB: gainDB) + [url.path]
    }

    static func aacEncodingArguments(settings: AudioSettings, gainDB: Double) -> [String] {
        [
            "-c:a", "aac_at", "-aac_at_mode", "cvbr",
            "-b:a", settings.bitrate,
            "-ar", "\(settings.sampleRate)",
            "-ac", settings.isMono ? "1" : "2"
        ] + loudnessFilterArguments(gainDB: gainDB)
    }

    static func loudnessFilterArguments(gainDB: Double) -> [String] {
        gainDB == 0 ? [] : ["-af", "volume=\(gainDB)dB"]
    }
}

extension FFmpegWrapper {
    static func writeConcatList(_ segments: [URL], to destination: URL) throws {
        let entries = segments.map { segment in
            let escaped = segment.path.replacingOccurrences(of: "'", with: "'\\''")
            return "file '\(escaped)'"
        }
        try entries.joined(separator: "\n").write(to: destination, atomically: true, encoding: .utf8)
    }
}
