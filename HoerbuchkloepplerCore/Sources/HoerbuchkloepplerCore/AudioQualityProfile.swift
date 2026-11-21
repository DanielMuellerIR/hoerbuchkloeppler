import Foundation

public enum AudioQualityProfile: String, CaseIterable, Identifiable, Sendable {
    case speechCompact, speechClear, music
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .speechCompact: return "Sprache kompakt · Mono, 48k, 32 kHz"
        case .speechClear: return "Sprache detailreich · Mono, 96k, 44,1 kHz"
        case .music: return "Musik und Hörspiel · Stereo, 192k, 48 kHz"
        }
    }
    public func applying(to original: AudioSettings) -> AudioSettings {
        var settings = original
        switch self {
        case .speechCompact: settings.isMono = true; settings.bitrate = "48k"; settings.sampleRate = 32000
        case .speechClear: settings.isMono = true; settings.bitrate = "96k"; settings.sampleRate = 44100
        case .music: settings.isMono = false; settings.bitrate = "192k"; settings.sampleRate = 48000
        }
        return settings
    }
}
