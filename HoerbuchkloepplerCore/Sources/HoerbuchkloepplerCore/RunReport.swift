import Foundation

/// Versionierter Laufbericht für JSON Lines; Diagnosen gehören auf stderr.
public struct RunReport: Codable, Sendable {
    public var schemaVersion = 1
    public var event: String
    public var phase: String
    public var progress: Double
    public var outputs: [String]
    public var success: Bool?
    public init(event: String, phase: String, progress: Double, outputs: [URL] = [], success: Bool? = nil) {
        self.event = event; self.phase = phase; self.progress = progress
        self.outputs = outputs.map(\.path); self.success = success
    }
}

public struct InspectionReport: Codable, Sendable {
    public var schemaVersion = 1
    public var metadata: BookMetadata
    public var settings: AudioSettings
    public var duration: Double
    public var chapters: [InspectedChapter]
    public var sourceIssues: [ProjectSourceIssue]
    public var outputs: [String]
    public var hasCover: Bool
    public init(session: ConversionSession, outputs: [URL]) async {
        metadata = await session.bookMetadata; settings = await session.settings
        let files = await session.audioFiles
        duration = files.reduce(0) { $0 + $1.duration }
        chapters = files.map { InspectedChapter(source: $0.sourceURL.path, readSource: $0.url.path, start: $0.startTime, duration: $0.duration, title: $0.chapterTitle) }
        sourceIssues = await session.projectSourceIssues
        self.outputs = outputs.map(\.path)
        hasCover = await session.coverImage != nil
    }
}
public struct InspectedChapter: Codable, Sendable {
    public var source: String
    public var readSource: String
    public var start: Double
    public var duration: Double
    public var title: String
}
