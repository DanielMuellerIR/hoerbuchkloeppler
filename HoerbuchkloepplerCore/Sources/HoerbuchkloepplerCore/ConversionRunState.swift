import Foundation

/// Maschinenwerte bleiben unabhängig von den deutschen Fortschrittstexten.
public enum ConversionPhase: String, Codable, Sendable, CaseIterable {
    case idle
    case input
    case preparing
    case measuringLoudness = "measuring_loudness"
    case decoding
    case encoding
    case muxing
}

/// Flüchtiger Laufzustand; wird ausdrücklich nicht im Projekt gespeichert.
public struct ConversionRunState: Sendable {
    public var isConverting = false
    public var showOverlay = false
    public var progress = 0.0
    public var status = "Bereit"
    public var phase = "Bereit"
    public var machinePhase: ConversionPhase = .idle
    public var completedOutputs: [URL] = []
    public var succeeded: Bool?
    public var segments: [Int: SegmentStatus] = [:]
    public init() {}

    /// Startzustand eines neuen Laufs. Ein eigener Initialisierer statt einer
    /// Liste von Einzelzuweisungen: Sonst muss jede Aufrufstelle alle
    /// Felder kennen, und ein vergessenes Feld trägt den Vorlauf weiter.
    public init(startingWith status: String) {
        self.init()
        isConverting = true
        showOverlay = true
        self.status = status
        phase = status
        machinePhase = .preparing
    }

    /// Zustand nach einer abgelehnten Startanforderung. Wie beim Start zählt:
    /// Es bleibt nichts vom Vorlauf stehen — sonst zeigte das Overlay neben
    /// „Keine Dateien" weiterhin 100 %, die alte Phase und die alte Ausgabe.
    public init(rejectedWith status: String) {
        self.init()
        self.status = status
        phase = status
        machinePhase = .preparing
        succeeded = false
    }
}
