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

    public init(
        isMono: Bool = true,
        bitrate: String = "48k",
        sampleRate: Int = 32000,
        maxDurationHours: Int? = nil,
        useParallelEncoding: Bool = true,
        isVerbose: Bool = false
    ) {
        self.isMono = isMono
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.maxDurationHours = maxDurationHours
        self.useParallelEncoding = useParallelEncoding
        self.isVerbose = isVerbose
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
        return result
    }
}
