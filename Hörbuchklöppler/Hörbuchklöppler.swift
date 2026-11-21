import HoerbuchkloepplerAppSupport
import HoerbuchkloepplerCore
import SwiftUI

@main
struct HoerbuchkloepplerApp: App {
    @NSApplicationDelegateAdaptor(DocumentOpenDelegate.self) private var documentDelegate

    var body: some Scene {
        WindowGroup(id: DocumentOpenCoordinator.windowID) {
            ContentView()
        }
        .handlesExternalEvents(matching: ["*"])
        .commands { ChapterUndoCommands() }
    }
}
