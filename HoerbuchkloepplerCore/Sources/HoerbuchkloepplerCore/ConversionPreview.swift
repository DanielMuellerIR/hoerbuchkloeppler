import Foundation

/// Konservative Zusatzbelegung: vorhandene Ausgaben bleiben bis zum atomaren
/// Austausch bestehen. Freier Platz ist daher mit dem zusätzlichen Bedarf zu vergleichen.
public struct ConversionPreview: Sendable {
    public let duration: Double
    public let chapterCount: Int
    public let outputURLs: [URL]
    public let tempVolume: URL
    public let targetVolume: URL
    public let tempBytes: Int64
    public let targetBytes: Int64
    public let availableTempBytes: Int64?
    public let availableTargetBytes: Int64?
    public var sharesVolume: Bool { tempVolume == targetVolume }

    public init(plan: ConversionPlan, settings: AudioSettings) {
        let files = plan.groups.flatMap { $0 }
        duration = files.reduce(0) { $0 + $1.duration }
        chapterCount = files.count
        outputURLs = plan.outputURLs
        let temp = FileManager.default.temporaryDirectory
        let target = plan.outputURLs.first?.deletingLastPathComponent() ?? temp
        tempVolume = Self.volume(of: temp)
        targetVolume = Self.volume(of: target)
        availableTempBytes = Self.freeBytes(at: temp)
        availableTargetBytes = Self.freeBytes(at: target)
        let normalized = settings.normalized()
        // `normalized()` hat die Bitrate bereits auf eine gültige Form gebracht;
        // der Default deckt den theoretischen Rest ab, statt hier abzustürzen.
        let bitrate = Double(normalized.bitsPerSecond ?? AudioSettings().bitsPerSecond ?? 48_000)
        let largestGroup = plan.groups.map { $0.reduce(0) { $0 + $1.duration } }.max() ?? 0
        // CVBR und Container haben Spielraum; 32 MiB je Ausgabe decken das Cover.
        targetBytes = Self.bytes(duration * bitrate / 8 * 1.25 + Double(plan.groups.count) * 32 * 1024 * 1024)
        let tempRate = normalized.useParallelEncoding
            ? bitrate / 8 * 1.25
            : Double(normalized.sampleRate * (normalized.isMono ? 1 : 2) * 2)
        let analysisBytes = normalized.analyzeLoudness || normalized.normalizeLoudness
            ? duration * Double(normalized.sampleRate * (normalized.isMono ? 1 : 2) * 2) : 0
        tempBytes = Self.bytes(max(largestGroup * tempRate, analysisBytes) + 32 * 1024 * 1024)
    }

    private static func bytes(_ value: Double) -> Int64 {
        guard value.isFinite, value < Double(Int64.max) else { return Int64.max }
        return Int64(max(0, value.rounded(.up)))
    }

    private static func volume(of url: URL) -> URL {
        (try? url.resourceValues(forKeys: [.volumeURLKey]).volume)?.standardizedFileURL ?? url
    }

    private static func freeBytes(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemFreeSize] as? NSNumber)?.int64Value
    }
}

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
