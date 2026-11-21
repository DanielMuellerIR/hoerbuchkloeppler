import Foundation
import Testing

@Suite("AppKit-Koordinatoren", .serialized)
@MainActor
struct AppSupportTests {}

struct FixtureFailure: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
