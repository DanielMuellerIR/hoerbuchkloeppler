import AppKit
import Combine

public enum WindowSheet: Hashable {
    case settings, conversionPreview, metadata, fileInfo
}

public struct PresentedWindowSheet: Identifiable {
    public let id: UUID
    public let kind: WindowSheet
    public fileprivate(set) var isPresented = true
}

public enum WindowSheetResult: Equatable {
    case dismissed, cancelled
}

@MainActor
public final class WindowPresentationCoordinator: ObservableObject {
    private enum Presentation {
        case sheet(WindowSheet, (WindowSheetResult) -> Void)
        case panel(NSSavePanel, (NSApplication.ModalResponse) -> Void)
        case alert(NSAlert, (Bool) -> Void)

        var sheetKind: WindowSheet? {
            if case .sheet(let kind, _) = self { kind } else { nil }
        }

        func cancel() {
            switch self {
            case .sheet(_, let completion): completion(.cancelled)
            case .panel(_, let completion): completion(.cancel)
            case .alert(_, let completion): completion(false)
            }
        }
    }

    @Published public private(set) var sheet: PresentedWindowSheet?
    private var pending: [Presentation] = []
    private var active: Presentation?
    private var activeToken: UUID?
    private var sheetHasAppeared = false
    private var completionDepth = 0
    private weak var window: NSWindow?
    private var onDetach: (() -> Void)?
    private var observers: Set<AnyCancellable> = []

    public init() {}

    public func attach(to window: NSWindow?, onDetach: @escaping () -> Void = {}) {
        guard self.window !== window || (window == nil && self.onDetach != nil) else { return }
        if self.onDetach != nil {
            detach()
            guard self.onDetach == nil else { return }
        }
        self.window = window
        guard let window else { return }
        self.onDetach = onDetach
        let notifications = NotificationCenter.default
        notifications.publisher(for: NSWindow.didEndSheetNotification, object: window)
            .sink { [weak self] _ in self?.scheduleNext() }
            .store(in: &observers)
        notifications.publisher(for: NSWindow.willCloseNotification, object: window)
            .sink { [weak self] _ in self?.detach() }
            .store(in: &observers)
        showNext()
    }

    public func present(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        enqueue(.panel(panel, completion))
    }

    public func present(_ alert: WindowAlert, completion: @escaping (Bool) -> Void = { _ in }) {
        enqueue(.alert(alert.makeAlert(), completion))
    }

    public func request(_ kind: WindowSheet, completion: @escaping (WindowSheetResult) -> Void = { _ in }) {
        guard !(sheet?.kind == kind && sheet?.isPresented == true), !isQueued(kind) else { return }
        enqueue(.sheet(kind, completion))
    }

    public func dismiss(_ kind: WindowSheet) {
        let ticket = sheet?.kind == kind ? sheet?.id : nil
        let removed = pending.filter { $0.sheetKind == kind }
        pending.removeAll { $0.sheetKind == kind }
        finishCallbacks {
            removed.forEach { $0.cancel() }
            if let ticket { dismissSheet(ticket) }
        }
    }

    public func isQueued(_ kind: WindowSheet) -> Bool {
        pending.contains { $0.sheetKind == kind }
    }

    public func sheetAppeared(_ id: UUID) {
        guard sheet?.id == id else { return }
        sheetHasAppeared = true
    }

    public func dismissSheet(_ id: UUID) {
        guard sheet?.id == id else { return }
        if sheetHasAppeared {
            sheet?.isPresented = false
        } else {
            // SwiftUI liefert vor onAppear möglicherweise kein onDismiss.
            completeSheet(id, result: .cancelled)
        }
    }

    public func sheetDismissed(_ id: UUID) {
        completeSheet(id, result: .dismissed)
    }

    private func completeSheet(_ id: UUID, result: WindowSheetResult) {
        guard sheet?.id == id, case .sheet(_, let completion) = active else { return }
        complete(id) { completion(result) }
    }

    private func enqueue(_ presentation: Presentation) {
        pending.append(presentation)
        showNext()
    }

    private func showNext() {
        guard completionDepth == 0, active == nil, let window, window.attachedSheet == nil, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        let token = UUID()
        active = next
        activeToken = token
        switch next {
        case .sheet(let kind, _):
            sheetHasAppeared = false
            sheet = PresentedWindowSheet(id: token, kind: kind)
        case .panel(let panel, let completion):
            panel.beginSheetModal(for: window) { [weak self] response in
                self?.complete(token) { completion(response) }
            }
        case .alert(let alert, let completion):
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.complete(token) { completion(response == .alertFirstButtonReturn) }
            }
        }
    }

    private func complete(_ token: UUID, completion: () -> Void) {
        guard token == activeToken else { return }
        // Der Callback darf synchron das Fenster wechseln. Dann darf detach()
        // den bereits abgeschlossenen Dialog nicht ein zweites Mal melden.
        finishCallbacks {
            active = nil
            activeToken = nil
            sheet = nil
            completion()
        }
    }

    private func finishCallbacks(_ callbacks: () -> Void) {
        completionDepth += 1
        defer {
            completionDepth -= 1
            if completionDepth == 0 { scheduleNext() }
        }
        callbacks()
    }

    private func scheduleNext() {
        Task { [weak self] in self?.showNext() }
    }

    public func detach() {
        finishCallbacks {
            let owner = window
            let active = self.active
            let pending = self.pending
            let onDetach = self.onDetach
            window = nil
            observers.removeAll()
            self.pending.removeAll()
            self.active = nil
            activeToken = nil
            sheetHasAppeared = false
            self.onDetach = nil
            sheet = nil
            // Erst alle Kennungen entwerten: AppKit kann beim Abbruch synchron antworten.
            switch active {
            case .panel(let panel, _):
                panel.cancel(nil)
            case .alert(let alert, _) where owner?.attachedSheet === alert.window:
                owner?.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
            default: break
            }
            active?.cancel()
            pending.forEach { $0.cancel() }
            onDetach?()
        }
    }
}
