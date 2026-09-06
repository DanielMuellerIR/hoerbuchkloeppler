import Foundation
import Testing
@testable import HoerbuchkloepplerCore

struct ConversionPreviewTests {
    @Test func durationWeightsProgress() {
        let tracker = ParallelProgressTracker(durations: [10, 90])
        #expect(abs(tracker.update(index: 0, progress: 1) - 0.1) < 0.0001)
        #expect(abs(tracker.update(index: 1, progress: 0.5) - 0.55) < 0.0001)
        #expect(abs(tracker.update(index: 1, progress: 0.1) - 0.55) < 0.0001)
    }

    @Test func previewUsesActualSplitAndLargestTemporaryGroup() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview.wav")
        let files = [AudioFile(url: url, startTime: 0, duration: 3500, chapterTitle: "A"),
                     AudioFile(url: url, startTime: 3500, duration: 3500, chapterTitle: "B")]
        let plan = FFmpegWrapper.makeConversionPlan(files: files, outputURL: url.deletingPathExtension().appendingPathExtension("m4b"), maxDurationHours: 1)
        let standard = ConversionPreview(plan: plan, settings: AudioSettings(useParallelEncoding: false))
        let parallel = ConversionPreview(plan: plan, settings: AudioSettings())
        #expect(standard.chapterCount == 2)
        #expect(standard.duration == 7000)
        #expect(standard.outputURLs.count == 2)
        #expect(standard.outputURLs == plan.outputURLs)
        #expect(standard.tempBytes == 3500 * 32000 * 2 + 32 * 1024 * 1024)
        #expect(parallel.tempBytes < standard.tempBytes)
        #expect(standard.targetBytes == parallel.targetBytes)
        #expect(standard.sharesVolume)
    }

    @Test func profilesKeepIndependentSettings() {
        let original = AudioSettings(maxDurationHours: 5, useParallelEncoding: false, workerLimit: 2)
        let settings = AudioQualityProfile.music.applying(to: original)
        #expect(settings.bitrate == "192k")
        #expect(!settings.isMono)
        #expect(settings.maxDurationHours == 5)
        #expect(settings.workerLimit == 2)
        #expect(!settings.useParallelEncoding)
        var manual = AudioSettings(isMono: false, bitrate: "256k")
        manual.isMono = true
        #expect(manual.normalized().bitrate == "256k")
    }
}
