import Foundation
import Testing
@testable import HoerbuchkloepplerCore

@Suite("Laufbericht-Schema 2")
struct RunReportTests {
    @Test("Jedes Ereignis enthält einen eindeutigen Erfolgszustand", arguments: RunReport.Event.allCases)
    func completeEvent(_ event: RunReport.Event) throws {
        let report = RunReport(event: event, phase: .encoding, progress: 0.4,
                               outputs: [URL(fileURLWithPath: "/tmp/Buch.m4b")])
        let data = try JSONEncoder().encode(report)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 2)
        #expect(object["event"] as? String == event.rawValue)
        #expect(object["phase"] as? String == "encoding")
        #expect(object["outputs"] as? [String] == ["/tmp/Buch.m4b"])
        switch event {
        case .started, .progress: #expect(object["success"] is NSNull)
        case .finished: #expect(object["success"] as? Bool == true)
        case .failed, .cancelled: #expect(object["success"] as? Bool == false)
        }
        let decoded = try JSONDecoder().decode(RunReport.self, from: data)
        #expect(decoded.event == event)
        #expect(decoded.phase == .encoding)
        #expect(decoded.success == report.success)
    }

    @MainActor
    @Test("Die Maschinenphase folgt dem Worker und bleibt nach Fehlern erhalten")
    func phaseSurvivesFailure() async {
        let session = ConversionSession(settings: AudioSettings())
        session.logSink = { _ in }
        session.runState = ConversionRunState(startingWith: "Beliebiger UI-Text")
        #expect(session.runState.machinePhase == .preparing)
        let context = session.beginConversionRun()
        session.enqueueSegmentReset(title: "Ein anderer UI-Text", phase: .measuringLoudness, runID: context.id)
        await session.flushConversionEvents()
        #expect(session.runState.machinePhase == .measuringLoudness)
        #expect(session.conversionPhase == "Ein anderer UI-Text")
        session.enqueueSegmentReset(title: "Dekodierung", phase: .decoding, runID: context.id)
        session.enqueueConversionFinished(success: false, cancelled: false, completedOutputs: [], runID: context.id)
        await session.flushConversionEvents()
        #expect(session.runState.machinePhase == .decoding)
        #expect(session.lastConversionSucceeded == false)
        #expect(!session.isConverting)
        session.enqueueSegmentReset(title: "Veraltete Meldung", phase: .muxing, runID: context.id)
        await session.flushConversionEvents()
        #expect(session.runState.machinePhase == .decoding)
    }
}
