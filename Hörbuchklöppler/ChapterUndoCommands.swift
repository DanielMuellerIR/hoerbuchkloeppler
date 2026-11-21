import AppKit
import HoerbuchkloepplerAppSupport
import SwiftUI

struct ChapterUndoCommands: Commands {
    @FocusedObject private var router: ChapterUndoRouter?

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Rückgängig") { router?.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(router?.canUndo != true)
            Button("Wiederholen") { router?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(router?.canRedo != true)
        }
    }
}

struct ProjectWindowReader: NSViewRepresentable {
    let router: ChapterUndoRouter
    let onWindowChange: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReader {
        WindowReader(router: router, onWindowChange: onWindowChange)
    }

    func updateNSView(_ nsView: WindowReader, context: Context) {}

    final class WindowReader: NSView {
        let router: ChapterUndoRouter
        let onWindowChange: @MainActor (NSWindow?) -> Void

        init(router: ChapterUndoRouter, onWindowChange: @escaping @MainActor (NSWindow?) -> Void) {
            self.router = router
            self.onWindowChange = onWindowChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Zustandsänderungen außerhalb des SwiftUI-View-Updates zustellen.
            Task { @MainActor [weak self] in
                guard let self else { return }
                router.attach(to: window)
                onWindowChange(window)
            }
        }
    }
}
