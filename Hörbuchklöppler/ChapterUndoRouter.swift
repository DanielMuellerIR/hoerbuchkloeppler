import AppKit
import Combine
import HoerbuchkloepplerCore
import SwiftUI

/// Textfelder behalten ihren eigenen Verlauf; Kapitelbefehle gehören zum
/// aktiven Projektfenster und dürfen nicht durch ein offenes Sheet wirken.
@MainActor
final class ChapterUndoRouter: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private weak var window: NSWindow?
    private weak var session: ConversionSession?
    private var beforeChapterEdit: (() -> Void)?
    private var subscriptions: Set<AnyCancellable> = []
    private var sessionSubscription: AnyCancellable?
    private let activeWindow: () -> NSWindow?

    init(activeWindow: @escaping () -> NSWindow? = { NSApp.keyWindow }) {
        self.activeWindow = activeWindow
        let names: [Notification.Name] = [
            NSWindow.didUpdateNotification,
            NSText.didBeginEditingNotification, NSText.didEndEditingNotification,
            NSText.didChangeNotification, .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup
        ]
        Publishers.MergeMany(names.map { NotificationCenter.default.publisher(for: $0) })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
    }

    func configure(session: ConversionSession, beforeChapterEdit: @escaping () -> Void) {
        self.session = session
        self.beforeChapterEdit = beforeChapterEdit
        sessionSubscription = session.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    func attach(to window: NSWindow?) {
        self.window = window
        refresh()
    }

    private var textEditor: NSTextView? {
        guard let editor = activeWindow()?.firstResponder as? NSTextView,
              editor.isEditable else { return nil }
        return editor
    }

    private var allowsChapterEdit: Bool {
        guard let window, activeWindow() === window, window.attachedSheet == nil,
              let session else { return false }
        return !session.isConverting && !session.isImporting
    }

    func refresh() {
        let undo: Bool
        let redo: Bool
        if let editor = textEditor {
            undo = editor.undoManager?.canUndo == true
            redo = editor.undoManager?.canRedo == true
        } else {
            undo = allowsChapterEdit && session?.canUndoChapters == true
            redo = allowsChapterEdit && session?.canRedoChapters == true
        }
        if canUndo != undo { canUndo = undo }
        if canRedo != redo { canRedo = redo }
    }

    func undo() {
        if let editor = textEditor {
            editor.undoManager?.undo()
        } else if allowsChapterEdit, session?.canUndoChapters == true {
            beforeChapterEdit?()
            session?.undoChapterEdit()
        }
        refresh()
    }

    func redo() {
        if let editor = textEditor {
            editor.undoManager?.redo()
        } else if allowsChapterEdit, session?.canRedoChapters == true {
            beforeChapterEdit?()
            session?.redoChapterEdit()
        }
        refresh()
    }
}

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

struct ChapterUndoWindowReader: NSViewRepresentable {
    let router: ChapterUndoRouter

    func makeNSView(context: Context) -> WindowReader {
        WindowReader(router: router)
    }

    func updateNSView(_ nsView: WindowReader, context: Context) {}

    final class WindowReader: NSView {
        let router: ChapterUndoRouter

        init(router: ChapterUndoRouter) {
            self.router = router
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Zustandsänderungen außerhalb des SwiftUI-View-Updates zustellen.
            Task { @MainActor [weak self] in
                guard let self else { return }
                router.attach(to: window)
            }
        }
    }
}
