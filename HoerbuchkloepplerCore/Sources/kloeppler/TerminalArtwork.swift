import AppKit
import HoerbuchkloepplerCore

enum TerminalArtwork {
    static func statusBlock(for state: ConversionRunState) -> String {
        var text = "Status: \(state.status)\n"
        for (index, segment) in state.segments.sorted(by: { $0.key < $1.key }) {
            let progress = pacmanBar(progress: segment.progress, width: 20)
            let key = String(format: "%03d", index)
            let file = segment.filename.prefix(25).padding(toLength: 25, withPad: " ", startingAt: 0)
            let percent = String(format: "%3d%%", Int(segment.progress * 100))
            text += "\(key) \(file) | \(progress) | \(percent)\n"
        }
        return text
    }

    private static func pacmanBar(progress: Double, width: Int) -> String {
        let filledCount = Int(progress * Double(width))
        let emptyCount = max(0, width - filledCount - 1)

        if progress >= 1.0 {
            return String(repeating: " ", count: width) + "ᗧ"
        }

        let spaces = String(repeating: " ", count: filledCount)
        let dots = String(repeating: "•", count: emptyCount)
        let mouthOpen = Int(Date().timeIntervalSince1970 * 5) % 2 == 0
        let pacman = mouthOpen ? "ᗧ" : "○"

        return spaces + pacman + dots
    }

    static func asciiCover(from image: NSImage, width: Int) -> String {
        let asciiChars = ["@", "%", "#", "*", "+", "=", "-", ":", ".", " "]

        // Ungültige Maße abfangen: Bei width == 0 ergäbe das Seitenverhältnis
        // unten NaN/Infinity, und Int(NaN) crasht zur Laufzeit.
        guard image.size.width > 0, image.size.height > 0,
              image.size.width.isFinite, image.size.height.isFinite,
              width > 0 else { return "" }

        // Der Aufrufer nutzt 40 Spalten. Die Obergrenzen schützen die Hilfs-
        // funktion zusätzlich vor riesigen Allokationen bei extremen Bildmaßen.
        let renderWidth = min(width, 400)

        var rect = NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return "" }

        // Terminalzeichen sind ungefähr doppelt so hoch wie breit.
        let aspectRatio = image.size.height / image.size.width
        let scaledHeight = Double(renderWidth) * Double(aspectRatio) * 0.5
        guard scaledHeight.isFinite else { return "" }
        let height = max(1, Int(min(200, scaledHeight)))

        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bytesPerPixel = 1
        let bytesPerRow = bytesPerPixel * renderWidth

        var pixelData = [UInt8](repeating: 0, count: renderWidth * height)

        // Der CGContext behält den übergebenen Zeiger und schreibt erst beim
        // späteren `draw` hinein. Ein `&pixelData` wäre nur für die Dauer des
        // CGContext-Aufrufs gültig; erzeugen, zeichnen und auslesen müssen
        // deshalb innerhalb desselben `withUnsafeMutableBytes`-Blocks liegen.
        return pixelData.withUnsafeMutableBytes { storage -> String in
            guard let base = storage.baseAddress,
                  let context = CGContext(data: base,
                                          width: renderWidth,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return "" }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: renderWidth, height: height))

            let pixels = storage.bindMemory(to: UInt8.self)
            var result = ""
            for y in 0..<height {
                for x in 0..<renderWidth {
                    let offset = (height - 1 - y) * renderWidth + x
                    let pixelValue = pixels[offset]
                    let charIndex = Int(Double(pixelValue) / 255.0 * Double(asciiChars.count - 1))
                    result += asciiChars[charIndex]
                }
                result += "\n"
            }
            return result
        }
    }
}
