import Foundation

/// Flüchtiger Laufzustand; wird ausdrücklich nicht im Projekt gespeichert.
public struct ConversionRunState: Sendable {
    public var isConverting = false
    public var showOverlay = false
    public var progress = 0.0
    public var status = "Bereit"
    public var phase = "Bereit"
    public var completedOutputs: [URL] = []
    public var succeeded: Bool?
    public var segments: [Int: SegmentStatus] = [:]
    public init() {}

    /// Startzustand eines neuen Laufs. Ein eigener Initialisierer statt einer
    /// Liste von Einzelzuweisungen: Sonst muss jede Aufrufstelle alle acht
    /// Felder kennen, und ein vergessenes Feld trägt den Vorlauf weiter.
    public init(startingWith status: String) {
        self.init()
        isConverting = true
        showOverlay = true
        self.status = status
        phase = status
    }
}
