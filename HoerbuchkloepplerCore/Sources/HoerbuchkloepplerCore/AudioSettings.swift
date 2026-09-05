import Foundation

public struct AudioSettings: Codable, Equatable, Sendable {
    public var isMono: Bool = true
    public var bitrate: String = "48k"
    // Standard-Abtastrate 32 kHz: Referenz für kleine Sprach-Hörbücher
    // (Mono, 32000 Hz, ~48 kbit/s) — platzsparend bei guter Sprachqualität.
    public var sampleRate: Int = 32000
    public var maxDurationHours: Int? = nil
    public var useParallelEncoding: Bool = true
    public var isVerbose: Bool = false
    /// nil begrenzt automatisch auf höchstens vier Prozesse.
    public var workerLimit: Int? = nil
    public var importWorkerLimit: Int = 4
    public var analyzeLoudness: Bool = false
    public var normalizeLoudness: Bool = false

    public var effectiveWorkerLimit: Int {
        max(1, min(32, workerLimit ?? 4, max(1, ProcessInfo.processInfo.activeProcessorCount)))
    }

    public init(
        isMono: Bool = true,
        bitrate: String = "48k",
        sampleRate: Int = 32000,
        maxDurationHours: Int? = nil,
        useParallelEncoding: Bool = true,
        isVerbose: Bool = false,
        workerLimit: Int? = nil,
        importWorkerLimit: Int = 4,
        analyzeLoudness: Bool = false,
        normalizeLoudness: Bool = false
    ) {
        self.isMono = isMono
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.maxDurationHours = maxDurationHours
        self.useParallelEncoding = useParallelEncoding
        self.isVerbose = isVerbose
        self.workerLimit = workerLimit
        self.importWorkerLimit = importWorkerLimit
        self.analyzeLoudness = analyzeLoudness
        self.normalizeLoudness = normalizeLoudness
    }

    /// Liest jedes Feld unabhängig. Eine alte oder von Hand bearbeitete Datei
    /// darf dadurch ein einzelnes fehlendes/falsch typisiertes Feld verlieren,
    /// ohne alle übrigen gültigen Einstellungen zu verwerfen.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AudioSettings()
        isMono = (try? values.decode(Bool.self, forKey: .isMono)) ?? defaults.isMono
        bitrate = (try? values.decode(String.self, forKey: .bitrate)) ?? defaults.bitrate
        sampleRate = (try? values.decode(Int.self, forKey: .sampleRate)) ?? defaults.sampleRate
        maxDurationHours = (try? values.decodeIfPresent(Int.self, forKey: .maxDurationHours))
            ?? defaults.maxDurationHours
        useParallelEncoding = (try? values.decode(Bool.self, forKey: .useParallelEncoding))
            ?? defaults.useParallelEncoding
        importWorkerLimit = (try? values.decode(Int.self, forKey: .importWorkerLimit)) ?? 4
        workerLimit = try? values.decodeIfPresent(Int.self, forKey: .workerLimit)
        analyzeLoudness = (try? values.decode(Bool.self, forKey: .analyzeLoudness)) ?? false
        normalizeLoudness = (try? values.decode(Bool.self, forKey: .normalizeLoudness)) ?? false
        isVerbose = (try? values.decode(Bool.self, forKey: .isVerbose)) ?? defaults.isVerbose
    }

    public static func isValidBitrate(_ value: String) -> Bool {
        guard value.range(of: "^[0-9]+k?$", options: .regularExpression) != nil else {
            return false
        }
        let digits = value.hasSuffix("k") ? String(value.dropLast()) : value
        guard let number = Int(digits), number > 0 else { return false }
        if value.hasSuffix("k") {
            let bitsPerSecond = number.multipliedReportingOverflow(by: 1_000)
            return !bitsPerSecond.overflow
                && (8_000...320_000).contains(bitsPerSecond.partialValue)
        }
        return (8_000...320_000).contains(number)
    }

    /// Korrupte oder manuell bearbeitete Persistenz darf keine ungültigen
    /// ffmpeg-Argumente erzeugen. Jedes fehlerhafte Feld fällt einzeln auf den
    /// dokumentierten Default zurück; gültige übrige Felder bleiben erhalten.
    public func normalized() -> AudioSettings {
        let defaults = AudioSettings()
        var result = self
        if !Self.isValidBitrate(result.bitrate) {
            result.bitrate = defaults.bitrate
        }
        if !(8_000...48_000).contains(result.sampleRate) {
            result.sampleRate = defaults.sampleRate
        }
        if let hours = result.maxDurationHours, hours <= 0 {
            result.maxDurationHours = defaults.maxDurationHours
        }
        if let limit = result.workerLimit, !(1...32).contains(limit) { result.workerLimit = nil }
        if !(1...8).contains(result.importWorkerLimit) { result.importWorkerLimit = 4 }
        return result
    }
}
