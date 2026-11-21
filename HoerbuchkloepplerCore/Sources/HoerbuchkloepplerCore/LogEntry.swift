import Foundation

public enum LogType: Sendable {
    case info      // Standardtext (Primary Color)
    case highlight // Pfade, Tool-Outputs, Befehle (AccentColor)
    case dim       // Light gray (MediaInfo output)
}

public struct LogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let type: LogType
    public let message: String
    public let date: Date
    public init(type: LogType, message: String, date: Date) { self.type = type; self.message = message; self.date = date }
}
