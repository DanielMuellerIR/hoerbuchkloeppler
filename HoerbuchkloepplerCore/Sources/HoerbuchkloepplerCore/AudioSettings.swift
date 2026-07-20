import Foundation

public struct AudioSettings: Codable, Equatable {
    public var isMono: Bool = true
    public var bitrate: String = "48k"
    // Standard-Abtastrate 32 kHz: Referenz für kleine Sprach-Hörbücher
    // (Mono, 32000 Hz, ~48 kbit/s) — platzsparend bei guter Sprachqualität.
    public var sampleRate: Int = 32000
    public var maxDurationHours: Int? = nil
    public var useParallelEncoding: Bool = true
    public var isVerbose: Bool = false
}
