import Foundation
import Combine
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import HoerbuchkloepplerCore

/// Besitzt Ausgabeauswahl, Vorschau, Überschreibbestätigung und Laufstart.
@MainActor final class OutputCoordinator: ObservableObject {
    @Published var previewPlan: ConversionPlan?
    @Published var showingConversionPreview = false
    @Published var showingOverwriteAlert = false
    @Published var pendingPlan: ConversionPlan?
    @Published var collidingOutputNames: [String] = []
    @Published var conversionStartError: String?

    func selectOutput(session: ConversionSession) {
        let savePanel = NSSavePanel()
        if #available(macOS 10.15, *) { savePanel.allowedContentTypes = [UTType.mpeg4Movie] } else { savePanel.allowedFileTypes = ["m4b", "mp4"] }
        savePanel.nameFieldStringValue = session.title.isEmpty ? "Hörbuch" : session.title
        savePanel.canCreateDirectories = true
        // Antwort-Behandlung gemeinsam, egal ob als Sheet oder modal gezeigt.
        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = savePanel.url {
                let finalURL = url.pathExtension.isEmpty ? url.appendingPathExtension("m4b") : url.deletingPathExtension().appendingPathExtension("m4b")
                let plan = FFmpegWrapper.makeConversionPlan(
                    files: session.audioFiles,
                    outputURL: finalURL,
                    maxDurationHours: session.settings.maxDurationHours
                )
                self.previewPlan = plan
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
        let collisions = plan.outputURLsRequiringOverwriteConfirmation
        if collisions.isEmpty { start(plan, session: session) }
        else { pendingPlan = plan; collidingOutputNames = collisions.map(\.lastPathComponent); showingOverwriteAlert = true }
    }

    func start(_ plan: ConversionPlan, session: ConversionSession) {
        switch FFmpegWrapper.convert(session: session, plan: plan) {
        case .started: conversionStartError = nil
        case .rejected(let message): conversionStartError = message
        }
    }
}
