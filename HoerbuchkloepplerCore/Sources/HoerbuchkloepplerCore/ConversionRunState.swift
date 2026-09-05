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
}
