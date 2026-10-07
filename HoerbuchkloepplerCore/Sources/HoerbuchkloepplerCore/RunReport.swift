import Foundation

/// Versionierter Laufbericht für JSON Lines; Diagnosen gehören auf stderr.
public struct RunReport: Codable, Sendable {
    public enum Event: String, Codable, Sendable, CaseIterable {
        case started, progress, finished, failed, cancelled
    }

    public let schemaVersion: Int
    public let event: Event
    public let phase: ConversionPhase
    public let progress: Double
    public let outputs: [String]
    public let success: Bool?

    public init(event: Event, phase: ConversionPhase, progress: Double, outputs: [URL] = []) {
        schemaVersion = 2
        self.event = event; self.phase = phase; self.progress = progress
        self.outputs = outputs.map(\.path)
        switch event {
        case .started, .progress: success = nil
        case .finished: success = true
        case .failed, .cancelled: success = false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, event, phase, progress, outputs, success
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(event, forKey: .event)
        try values.encode(phase, forKey: .phase)
        try values.encode(progress, forKey: .progress)
        try values.encode(outputs, forKey: .outputs)
        if let success { try values.encode(success, forKey: .success) }
        else { try values.encodeNil(forKey: .success) }
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
