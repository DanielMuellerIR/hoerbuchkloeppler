import Foundation
import Testing
@testable import HoerbuchkloepplerCore
import AVFoundation
import CoreGraphics
import ImageIO

func makeTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("HoerbuchkloepplerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

func writeExecutable(_ url: URL, _ contents: String) throws {
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

func testAudioFile(_ url: URL, duration: TimeInterval = 1) -> AudioFile {
    AudioFile(url: url, startTime: 0, duration: duration, chapterTitle: url.lastPathComponent)
}

func writeSilentWAV(to url: URL, duration: TimeInterval = 0.25) throws {
    let sampleRate = 8_000.0
    let format = try #require(
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
    )
    let frameCount = AVAudioFrameCount(sampleRate * duration)
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
    )
    buffer.frameLength = frameCount
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

func onePixelPNGData(channelValue: UInt8 = 255) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytes = [UInt8](repeating: channelValue, count: 4)
    let image = bytes.withUnsafeBytes { storage -> CGImage? in
        guard let context = CGContext(
            data: UnsafeMutableRawPointer(mutating: storage.baseAddress),
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return context.makeImage()
    }
    let cgImage = try #require(image)
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data,
        "public.png" as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, cgImage, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

final class ThreadSafeLogProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}
