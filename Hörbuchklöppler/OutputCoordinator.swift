import Foundation
import Combine
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import HoerbuchkloepplerCore

/// Besitzt Ausgabeauswahl, Vorschau, Überschreibbestätigung und Laufstart.
@MainActor final class OutputCoordinator: ObservableObject {
    @Published var previewPlan: ConversionPlan?
    /// Einmal beim Öffnen des Sheets gebaut. `ConversionPreview.init` fragt
    /// synchron Volume und freien Platz ab; im ViewBuilder stünde das bei jeder
    /// Body-Auswertung erneut auf dem Main Actor — bei einem Netzlaufwerk friert
    /// die Oberfläche dabei ein.
    @Published var preview: ConversionPreview?
    @Published var showingConversionPreview = false
    @Published var showingOverwriteAlert = false
    @Published var pendingPlan: ConversionPlan?
    @Published var collidingOutputNames: [String] = []
    @Published var conversionStartError: String?

    func selectOutput(session: ConversionSession) {
        let savePanel = NSSavePanel()
        // Die Endung des Panels muss die sein, die auch geschrieben wird. Mit
        // `mpeg4Movie` hängte das Panel an ein bewusst getipptes „Buch.m4b" noch
        // `.mp4` an, und die Zeile darunter machte daraus „Buch.m4b.m4b".
        savePanel.allowedContentTypes = [UTType(filenameExtension: "m4b") ?? .mpeg4Movie]
        savePanel.nameFieldStringValue = session.title.isEmpty ? "Hörbuch" : session.title
        savePanel.canCreateDirectories = true
        // Antwort-Behandlung gemeinsam, egal ob als Sheet oder modal gezeigt.
        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = savePanel.url {
                // Nur anhängen, wenn nötig: `deletingPathExtension` schnitte
                // sonst auch aus „Teil 2.0" die vermeintliche Endung heraus.
                let finalURL = url.pathExtension.lowercased() == "m4b"
                    ? url
                    : url.appendingPathExtension("m4b")
                let plan = FFmpegWrapper.makeConversionPlan(
                    files: session.audioFiles,
                    outputURL: finalURL,
                    maxDurationHours: session.settings.maxDurationHours
                )
                self.previewPlan = plan
                self.preview = ConversionPreview(plan: plan, settings: session.settings)
                self.showingConversionPreview = true
            }
        }
        // Kein Force-Unwrap auf NSApp.mainWindow (kann nil sein -> Crash).
        // Vorhandenes Fenster als Sheet-Parent nutzen, sonst Panel modal zeigen.
        if let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first {
            savePanel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(savePanel.runModal())
        }
    }

    func confirmPreview(_ plan: ConversionPlan, session: ConversionSession) {
        showingConversionPreview = false
        preview = nil
        previewPlan = nil
        let collisions = plan.outputURLsRequiringOverwriteConfirmation
        if collisions.isEmpty { start(plan, session: session); return }
        pendingPlan = plan
        collidingOutputNames = collisions.map(\.lastPathComponent)
        // Erst im nächsten Durchlauf anfordern: Sheet-Abbau und Alert-Aufbau im
        // selben Zustandsupdate lässt AppKit den Alert verschlucken — dann
        // passierte gar nichts, ohne Meldung und ohne Lauf.
        Task { @MainActor in self.showingOverwriteAlert = true }
    }

    func start(_ plan: ConversionPlan, session: ConversionSession) {
        pendingPlan = nil
        previewPlan = nil
        collidingOutputNames = []
        switch FFmpegWrapper.convert(session: session, plan: plan) {
        case .started: conversionStartError = nil
        case .rejected(let message): conversionStartError = message
        }
    }

    /// Der Nutzer hat die Überschreibfrage verneint; der zurückgehaltene Plan
    /// samt seiner Datei-Snapshots darf dann nicht die Sitzung überdauern.
    func cancelOverwrite() {
        pendingPlan = nil
        previewPlan = nil
        collidingOutputNames = []
    }

    /// Verwirft die Vorschau und den darin festgehaltenen Datei-Snapshot.
    func cancelPreview() {
        showingConversionPreview = false
        preview = nil
        previewPlan = nil
    }
}
