import AppKit
import Testing
@testable import HoerbuchkloepplerAppSupport
@testable import HoerbuchkloepplerCore

@MainActor
private func hiddenWindow() -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
}

@MainActor
private func waitForPresentation(_ description: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw FixtureFailure(description) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private final class ExportFixture {
    let directory: URL
    let session = ConversionSession(settings: AudioSettings())
    let output = OutputCoordinator()
    let coverDrop = CoverDropCoordinator()
    let presentation = WindowPresentationCoordinator()
    let window = hiddenWindow()

    var destination: URL { directory.appendingPathComponent("Ausgabe.m4b") }
    var project: URL { directory.appendingPathComponent("Buch.hkproject") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HKExport-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("Kapitel.wav")
        try Data("Lokal erzeugte Quelldatei für den Projekt-Fingerprint".utf8).write(to: source)
        session.audioFiles = [AudioFile(url: source, startTime: 0, duration: 1, chapterTitle: "Kapitel")]
        session.title = "Testbuch"
        presentation.attach(to: window) { [weak output, weak coverDrop] in
            output?.cancelWork()
            coverDrop?.cancel()
        }
    }

    func cleanup() {
        presentation.detach()
        try? FileManager.default.removeItem(at: directory)
    }

    func preparePreview() {
        output.conversionStartError = nil
        output.preparePreview(at: destination, bookmark: ExportBookmark(session), session: session,
                              coverDrop: coverDrop, presentation: presentation)
    }

    func appearPreview() async throws -> UUID {
        preparePreview()
        try await waitForPresentation("Ausgabevorschau fehlt") {
            output.preview != nil && presentation.sheet?.kind == .conversionPreview
        }
        let ticket = try #require(presentation.sheet?.id)
        presentation.sheetAppeared(ticket)
        return ticket
    }

    func confirmPreview(_ ticket: UUID) {
        output.confirmPreview(ticket, session: session, coverDrop: coverDrop, presentation: presentation)
    }

    func dismissPreview(_ ticket: UUID) {
        presentation.dismissSheet(ticket)
        presentation.sheetDismissed(ticket)
    }

    func expectNoExport() {
        #expect(!session.isConverting)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

extension AppSupportTests {
    @Test("Dialogabschluss kann synchron das Besitzerfenster wechseln", arguments: [false, true])
    func completionCanChangeOwner(native: Bool) async throws {
        let owner = hiddenWindow()
        let replacement = hiddenWindow()
        owner.alphaValue = 0
        defer { owner.orderOut(nil) }
        let presentation = WindowPresentationCoordinator()
        presentation.attach(to: owner)
        defer { presentation.detach() }
        var results: [Bool] = []
        var queuedResults: [WindowSheetResult] = []
        let completion: (Bool) -> Void = { accepted in
            results.append(accepted)
            presentation.attach(to: replacement)
            presentation.request(.metadata)
            #expect(presentation.sheet == nil, "Der nächste Dialog beginnt erst nach dem Callback")
        }

        if native {
            presentation.present(.error(title: "Test", message: "Abschluss wechselt das Fenster."), completion: completion)
            let sheet = try #require(owner.attachedSheet)
            sheet.alphaValue = 0
            presentation.request(.fileInfo) { queuedResults.append($0) }
            owner.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        } else {
            presentation.request(.settings) { completion($0 == .dismissed) }
            let ticket = try #require(presentation.sheet?.id)
            presentation.request(.fileInfo) { queuedResults.append($0) }
            presentation.sheetAppeared(ticket)
            presentation.dismissSheet(ticket)
            presentation.sheetDismissed(ticket)
        }

        try await waitForPresentation("Der Dialog des neuen Fensters fehlt") { presentation.sheet?.kind == .metadata }
        #expect(results == [true])
        #expect(queuedResults == [.cancelled])
    }

    @Test("Vorgemerkte Sheets warten auf den wirklichen AppKit-Sheet-Abschluss")
    func externalNativeSheetBlocksPresentation() async throws {
        let owner = hiddenWindow()
        let nativeSheet = hiddenWindow()
        owner.alphaValue = 0
        nativeSheet.alphaValue = 0
        defer { owner.orderOut(nil) }
        let presentation = WindowPresentationCoordinator()
        presentation.attach(to: owner)
        defer { presentation.detach() }
        owner.beginSheet(nativeSheet, completionHandler: nil)
        try #require(owner.attachedSheet === nativeSheet)
        presentation.request(.settings)
        #expect(presentation.sheet == nil)
        owner.endSheet(nativeSheet)
        try await waitForPresentation("Die AppKit-Meldung hat das vorgemerkte Sheet nicht freigegeben") {
            presentation.sheet?.kind == .settings
        }
    }

    @Test("Vor dem Einblenden abgebrochenes Sheet gibt die Warteschlange frei")
    func dismissBeforeSheetAppears() async throws {
        let owner = hiddenWindow()
        let presentation = WindowPresentationCoordinator()
        presentation.attach(to: owner)
        defer { presentation.detach() }
        var results: [WindowSheetResult] = []
        presentation.request(.metadata) { results.append($0) }
        let first = try #require(presentation.sheet)
        presentation.request(.fileInfo) { results.append($0) }

        presentation.dismissSheet(first.id)
        try await waitForPresentation("Nachfolgendes Sheet fehlt") { presentation.sheet?.kind == .fileInfo }
        let second = try #require(presentation.sheet)
        #expect(first.id != second.id)
        #expect(results == [.cancelled])
        presentation.sheetAppeared(first.id)
        presentation.sheetDismissed(first.id)
        presentation.dismissSheet(first.id)
        #expect(presentation.sheet?.id == second.id)
        #expect(results == [.cancelled])

        presentation.sheetAppeared(second.id)
        presentation.dismissSheet(second.id)
        #expect(presentation.sheet?.isPresented == false)
        #expect(results == [.cancelled])
        presentation.sheetDismissed(second.id)
        #expect(results == [.cancelled, .dismissed])
    }

    @Test("Fensterablösung räumt die Vorschau und die vorgemerkte Projektbestätigung ab", arguments: [false, true])
    func detachAbandonsPreviewAndProjectConfirmation(queuedPreview: Bool) async throws {
        let fixture = try ExportFixture()
        defer { fixture.cleanup() }
        let opener = DocumentOpenCoordinator()
        try await fixture.session.saveProjectAsync(to: fixture.project)
        let oldTicket: UUID
        if queuedPreview {
            fixture.presentation.request(.settings)
            oldTicket = try #require(fixture.presentation.sheet?.id)
            fixture.preparePreview()
            try await waitForPresentation("Vorgemerkte Vorschau fehlt") { fixture.output.preview != nil }
            #expect(fixture.presentation.isQueued(.conversionPreview))
        } else {
            oldTicket = try await fixture.appearPreview()
            fixture.confirmPreview(oldTicket)
        }
        opener.receive(fixture.project, session: fixture.session, beforeOpening: {})
        try await waitForPresentation("Projektbestätigung fehlt") { opener.projectToConfirm == fixture.project }
        fixture.presentation.present(.openProject(fixture.project)) { accepted in
            if !accepted { opener.cancelProject() }
        }

        let replacement = hiddenWindow()
        if !queuedPreview { fixture.window.close() }
        fixture.presentation.attach(to: replacement)
        #expect(fixture.output.preview == nil)
        #expect(opener.projectToConfirm == nil)
        fixture.expectNoExport()
        fixture.presentation.request(.metadata)
        let replacementTicket = try #require(fixture.presentation.sheet?.id)
        fixture.presentation.sheetDismissed(oldTicket)
        #expect(fixture.presentation.sheet?.id == replacementTicket)

        opener.receive(fixture.project, session: fixture.session, beforeOpening: {})
        try await waitForPresentation("Neue Projektöffnung wurde blockiert") {
            opener.projectToConfirm == fixture.project
        }
    }

    @Test("Änderungen während Planung und Vorschau entwerten den Export")
    func previewRejectsChangedBook() async throws {
        let fixture = try ExportFixture()
        defer { fixture.cleanup() }
        fixture.preparePreview()
        #expect(fixture.output.activity == .preparingPreview)
        fixture.session.title = "Während der Planung geändert"
        try await waitForPresentation("Planung endet nicht") { fixture.output.activity == nil }
        #expect(fixture.output.preview == nil)
        #expect(fixture.output.conversionStartError != nil)

        let ticket = try await fixture.appearPreview()
        fixture.session.settings.isMono.toggle()
        fixture.confirmPreview(ticket)
        fixture.dismissPreview(ticket)
        #expect(fixture.output.conversionStartError != nil)
        fixture.expectNoExport()

        let replacement = try await fixture.appearPreview()
        fixture.confirmPreview(ticket)
        fixture.dismissPreview(replacement)
        #expect(fixture.output.activity == nil)
        #expect(fixture.output.conversionStartError == nil)
        fixture.expectNoExport()
    }

    @Test("Speichern unter, manueller Cover-Drop und Quellprüfung entwerten alte Freigaben")
    func confirmedExportRejectsChangedBook() async throws {
        let fixture = try ExportFixture()
        defer { fixture.cleanup() }
        try await fixture.session.saveProjectAsync(to: fixture.project)
        let files = fixture.session.audioFiles
        let beforeSaveAs = try await fixture.appearPreview()
        fixture.confirmPreview(beforeSaveAs)
        try await fixture.session.saveProjectAsync(to: fixture.directory.appendingPathComponent("Kopie.hkproject"))
        #expect(files == fixture.session.audioFiles)
        fixture.dismissPreview(beforeSaveAs)
        #expect(fixture.output.conversionStartError != nil)
        fixture.expectNoExport()

        let beforeCover = try await fixture.appearPreview()
        fixture.confirmPreview(beforeCover)
        let provider = NSItemProvider()
        provider.registerObject(ofClass: NSURL.self, visibility: .all) { _ in Progress(totalUnitCount: 1) }
        fixture.coverDrop.load(provider, session: fixture.session)
        #expect(fixture.coverDrop.isPending)
        fixture.dismissPreview(beforeCover)
        #expect(fixture.output.conversionStartError != nil)
        fixture.expectNoExport()
        fixture.coverDrop.cancel()

        let beforeSources = try await fixture.appearPreview()
        fixture.confirmPreview(beforeSources)
        fixture.dismissPreview(beforeSources)
        #expect(fixture.output.activity == .checkingSources)
        fixture.session.title = "Während der Quellprüfung geändert"
        try await waitForPresentation("Quellprüfung endet nicht") { fixture.output.activity == nil }
        #expect(fixture.output.conversionStartError != nil)
        fixture.expectNoExport()
    }
}
