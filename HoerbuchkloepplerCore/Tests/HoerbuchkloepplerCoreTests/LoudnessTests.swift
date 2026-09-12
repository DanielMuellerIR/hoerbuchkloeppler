import Foundation
import Testing
import CoreGraphics
import ImageIO
@testable import HoerbuchkloepplerCore

@Suite("Buchlautheit", .serialized)
struct LoudnessTests {
    @MainActor
    private func waitForConversion(
        _ session: ConversionSession,
        timeout: Duration = .seconds(30)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while session.isConverting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard session.isConverting else { return true }

        Issue.record("Konvertierung lief nach \(timeout) noch; Testlauf wird abgebrochen")
        _ = FFmpegWrapper.cancelConversion(session: session)
        let cleanupDeadline = ContinuousClock.now + .seconds(5)
        while session.isConverting, ContinuousClock.now < cleanupDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if session.isConverting {
            Issue.record("Abbruchbereinigung endete nicht innerhalb von 5 Sekunden")
        }
        return false
    }

    @Test func commonGainPreservesDynamicsAndPeakHeadroom() throws {
        let result = try LoudnessMeasurement.parse(Data("noise\n{\"input_i\":\"-26.5\",\"input_tp\":\"-3.0\"}\n".utf8))
        #expect(result.gainDB == 2)
        #expect(LoudnessMeasurement(integratedLUFS: -14, truePeakDB: -2).gainDB == -4)
        #expect(LoudnessMeasurement(integratedLUFS: -18, truePeakDB: -2).gainDB == 0)
        #expect(throws: (any Error).self) {
            try LoudnessMeasurement.parse(Data("{\"input_i\":\"-inf\",\"input_tp\":\"-inf\"}".utf8))
        }
    }

    /// Prüft ausschließlich, was der GUI-Handoff BAUT. Dass der echte Parser
    /// diese Optionen auch annimmt, prüft `tests/verify_cli_matrix.py` — ein
    /// Umbenennen von `--normalize-loudness` bliebe hier sonst unbemerkt.
    @Test func handoffCarriesMetadataAndLoudnessOptions() throws {
        #expect(try BookMetadata.outputLanguage("de") == "deu")
        #expect(try BookMetadata.outputLanguage("de-DE") == "deu")
        #expect(throws: (any Error).self) { try BookMetadata.outputLanguage("Deutsch") }
        #expect(throws: (any Error).self) { try BookMetadata.validateVolumeNumber("70000") }
        let invocation = CLIInvocation(executable: "kloeppler", folderURL: URL(fileURLWithPath: "/tmp"), settings: AudioSettings(normalizeLoudness: true), title: "", author: "", narrator: "Ada", series: "Reihe", volumeNumber: "2", language: "deu")
        #expect(invocation.arguments.contains("--normalize-loudness"))
        #expect(invocation.arguments.contains("--narrator=Ada"))
        #expect(invocation.arguments.contains("--volume-number=2"))
    }

    @Test func defaultsAndRoundtrip() throws {
        let defaults = try JSONDecoder().decode(AudioSettings.self, from: Data("{}".utf8))
        #expect(!defaults.analyzeLoudness && !defaults.normalizeLoudness)
        let settings = AudioSettings(analyzeLoudness: true, normalizeLoudness: true)
        #expect(try JSONDecoder().decode(AudioSettings.self, from: JSONEncoder().encode(settings)) == settings)
        #expect(FFmpegWrapper.loudnessFilterArguments(gainDB: 0).isEmpty)
        #expect(FFmpegWrapper.loudnessFilterArguments(gainDB: -3) == ["-af", "volume=-3.0dB"])
    }

    @Test(arguments: [false, true]) @MainActor func realBookAnalysisInBothModes(split: Bool) async throws {
        guard let ffmpeg = FFmpegWrapper.getBinaryURL(name: "ffmpeg") else {
            // Ohne Meldung verschwände hier die gesamte Abdeckung des echten
            // Encodings spurlos: `Resources/bin/ffmpeg` ist nicht eingecheckt
            // und entsteht erst durch `./build.sh --deps-only`.
            Issue.record("ffmpeg fehlt — vorher ./build.sh --deps-only ausführen")
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LoudnessTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input.wav")
        let generated = FFmpegWrapper.runCapturedProcess(executableURL: ffmpeg, arguments: ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=4", "-af", "volume=0.3", input.path], timeout: 10)
        guard case .completed(let status, _) = generated, status == 0 else { Issue.record("Fixture-Erzeugung fehlgeschlagen"); return }
        let imageData = NSMutableData()
        let color = CGColorSpaceCreateDeviceRGB()
        let canvas = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: color, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let destination = try #require(CGImageDestinationCreateWithData(imageData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(canvas.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        for parallel in [false, true] {
            let session = ConversionSession(settings: AudioSettings(useParallelEncoding: parallel, workerLimit: 2, normalizeLoudness: true))
            session.logSink = { _ in }
            session.title = "Buch"
            session.embeddedCoverData = imageData as Data
            session.narrator = "Sprecher"; session.series = "Reihe"; session.volumeNumber = "2"; session.language = "deu"
            session.audioFiles = [AudioFile(url: input, startTime: 0, duration: 2, chapterTitle: "A"), AudioFile(url: input, startTime: 2, duration: 2, chapterTitle: "B")]
            let output = folder.appendingPathComponent("result-\(parallel).m4b")
            let initialPlan = FFmpegWrapper.makeConversionPlan(files: session.audioFiles, outputURL: output, maxDurationHours: nil)
            let secondPlan = FFmpegWrapper.makeConversionPlan(files: session.audioFiles, outputURL: folder.appendingPathComponent("second-\(parallel).m4b"), maxDurationHours: nil)
            let plan = split ? ConversionPlan(groups: session.audioFiles.map { [$0] }, outputURLs: initialPlan.outputURLs + secondPlan.outputURLs, outputSnapshots: initialPlan.outputSnapshots + secondPlan.outputSnapshots, outputDirectorySnapshots: initialPlan.outputDirectorySnapshots + secondPlan.outputDirectorySnapshots, inputSnapshots: initialPlan.inputSnapshots) : initialPlan
            guard case .started = FFmpegWrapper.convert(session: session, plan: plan) else { Issue.record("Start abgelehnt"); continue }
            guard await waitForConversion(session) else { continue }
            #expect(session.lastConversionSucceeded == true)
            #expect(FileManager.default.fileExists(atPath: output.path))
            if split { #expect(FileManager.default.fileExists(atPath: secondPlan.outputURLs[0].path)) }
            let decoded = FFmpegWrapper.runCapturedProcess(executableURL: ffmpeg, arguments: ["-nostdin", "-hide_banner", "-nostats", "-i", output.path, "-af", "loudnorm=I=-18:TP=-1:LRA=50:print_format=json", "-f", "null", "-"], timeout: 10)
            if case .completed(let exit, let data) = decoded {
                #expect(exit == 0)
                let measurement = try LoudnessMeasurement.parse(data)
                #expect(abs(measurement.integratedLUFS + 18) < 0.6)
                let text = String(decoding: data, as: UTF8.self)
                #expect(text.contains("attached pic"))
                #expect(text.contains("Sprecher")); #expect(text.contains("Reihe"))
                #expect(text.contains("disc")); #expect(text.contains("deu"))
            } else { Issue.record("Ausgabeanalyse fehlgeschlagen") }
        }
    }

    /// Schließt die in `docs/build-and-test.md` benannten Lücken: reine Analyse
    /// ohne Pegeländerung, Fehlschlag der Analyse und Fehlschlag der
    /// Angleichung. Möglich wird das über die Testnaht `measureBookLoudness`.
    @MainActor
    private func runWithMeasurement(
        folder: URL,
        input: URL,
        name: String,
        settings: AudioSettings,
        measure: @escaping @Sendable () throws -> LoudnessMeasurement
    ) async -> (session: ConversionSession, output: URL, logs: [String]) {
        let session = ConversionSession(settings: settings)
        session.logSink = { _ in }
        session.title = "Buch"
        session.audioFiles = [
            AudioFile(url: input, startTime: 0, duration: 2, chapterTitle: "A")
        ]
        let output = folder.appendingPathComponent("\(name).m4b")
        let plan = FFmpegWrapper.makeConversionPlan(
            files: session.audioFiles,
            outputURL: output,
            maxDurationHours: nil
        )
        guard case .started = FFmpegWrapper.convert(
            session: session,
            plan: plan,
            measureBookLoudness: measure
        ) else {
            Issue.record("Start abgelehnt")
            return (session, output, [])
        }
        guard await waitForConversion(session) else {
            return (session, output, session.eventLogs.map(\.message))
        }
        return (session, output, session.eventLogs.map(\.message))
    }

    @Test @MainActor func analysisOnlyKeepsLevelAndSurvivesFailure() async throws {
        guard let ffmpeg = FFmpegWrapper.getBinaryURL(name: "ffmpeg") else {
            Issue.record("ffmpeg fehlt — vorher ./build.sh --deps-only ausführen")
            return
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoudnessPolicy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input.wav")
        let generated = FFmpegWrapper.runCapturedProcess(
            executableURL: ffmpeg,
            arguments: [
                "-nostdin", "-v", "error", "-f", "lavfi",
                "-i", "sine=frequency=440:duration=2",
                "-af", "volume=0.3", input.path
            ],
            timeout: 10
        )
        guard case .completed(let status, _) = generated, status == 0 else {
            Issue.record("Fixture-Erzeugung fehlgeschlagen"); return
        }
        // Ein Messwert, der bei aktivierter Angleichung einen Gain ungleich 0
        // ergäbe: -26,5 LUFS bei -3 dBTP.
        let loud = LoudnessMeasurement(integratedLUFS: -26.5, truePeakDB: -3)
        #expect(loud.gainDB != 0)

        // 1. Reine Analyse: Der Messwert wird berichtet, der Pegel bleibt.
        let analysed = await runWithMeasurement(
            folder: folder, input: input, name: "analyse",
            settings: AudioSettings(analyzeLoudness: true, normalizeLoudness: false),
            measure: { loud }
        )
        #expect(analysed.session.lastConversionSucceeded == true)
        #expect(FileManager.default.fileExists(atPath: analysed.output.path))
        #expect(analysed.logs.contains { $0.contains("Analyse ohne Pegeländerung") })
        #expect(!analysed.logs.contains { $0.contains("gemeinsamer Gain") })

        // 2. Fehlgeschlagene reine Analyse: Die Auskunft entfällt, das Hörbuch
        //    entsteht trotzdem.
        let failedAnalysis = await runWithMeasurement(
            folder: folder, input: input, name: "analyse-fehler",
            settings: AudioSettings(analyzeLoudness: true, normalizeLoudness: false),
            measure: { throw NSError(domain: "Test", code: 1) }
        )
        #expect(failedAnalysis.session.lastConversionSucceeded == true)
        #expect(FileManager.default.fileExists(atPath: failedAnalysis.output.path))
        #expect(failedAnalysis.logs.contains {
            $0.contains("läuft ohne Messwert weiter")
        })

        // 3. Fehlgeschlagene Angleichung: Der Nutzer wollte die Pegeländerung,
        //    ein Buch ohne sie wäre etwas anderes als das Bestellte.
        let failedNormalisation = await runWithMeasurement(
            folder: folder, input: input, name: "angleichung-fehler",
            settings: AudioSettings(analyzeLoudness: false, normalizeLoudness: true),
            measure: { throw NSError(domain: "Test", code: 1) }
        )
        #expect(failedNormalisation.session.lastConversionSucceeded == false)
        #expect(!FileManager.default.fileExists(atPath: failedNormalisation.output.path))
        #expect(failedNormalisation.logs.contains {
            $0.contains("Lautheitsanalyse fehlgeschlagen:")
        })
    }
}
