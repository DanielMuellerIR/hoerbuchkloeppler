import Foundation
import Darwin

private struct TerminalSize: Equatable {
    let columns: Int
    let rows: Int
    let revision: UInt
}

/// Auch ein Schrumpfen und anschließendes Vergrößern auf dieselben Maße
/// entwertet die frühere Cursorposition. SIGWINCH hält diese Information fest.
private final class TerminalGeometry: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt = 0
    private let source: DispatchSourceSignal

    init() {
        source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            lock.lock()
            revision &+= 1
            lock.unlock()
        }
        source.resume()
    }

    deinit { source.cancel() }

    func size(fileDescriptor: Int32) -> TerminalSize {
        var size = winsize()
        _ = ioctl(fileDescriptor, TIOCGWINSZ, &size)
        lock.lock()
        defer { lock.unlock() }
        return TerminalSize(columns: size.ws_col > 0 ? Int(size.ws_col) : 80,
                            rows: size.ws_row > 0 ? Int(size.ws_row) : 24,
                            revision: revision)
    }
}

private final class TerminalCharacterWidth {
    private let locale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil)

    deinit {
        if let locale { freelocale(locale) }
    }

    func cells(_ character: Character) -> Int {
        let scalars = character.unicodeScalars
        // Variation Selector und Emoji-Sequenzen belegen gemeinsam eine Glyphe,
        // keine Zelle pro Codepoint. Überzählige Breite wäre zwar sicher, ließe
        // aber beispielsweise Familien-Emoji unnötig allein in einer Zeile.
        if scalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F || $0.value == 0x200D }) {
            return 2
        }
        guard let locale else { return max(1, character.utf16.count) }
        let previous = uselocale(locale)
        defer { uselocale(previous) }
        return scalars.reduce(0) { total, scalar in
            let cells = Int(wcwidth(wchar_t(scalar.value)))
            return total + (cells < 0 ? 1 : cells)
        }
    }
}

/// Statuszeilen werden vor dem Schreiben in physische Terminalzeilen zerlegt.
/// Alle dauerhaften Logs laufen ebenfalls hierdurch und bleiben oberhalb des
/// löschbaren Blocks. Aufrufe gehören ausschließlich zum Main Actor.
@MainActor
final class TerminalRenderer {
    private var blockLines = 0
    private var blockSize: TerminalSize?
    private var lastPlainStatus = ""
    private let outputFileDescriptor: Int32
    private let geometry: TerminalGeometry?
    private let characterWidth = TerminalCharacterWidth()

    init(outputFileDescriptor: Int32 = FileHandle.standardOutput.fileDescriptor) {
        self.outputFileDescriptor = outputFileDescriptor
        geometry = isatty(outputFileDescriptor) != 0 ? TerminalGeometry() : nil
    }

    func clearBlock() {
        guard let geometry, blockLines > 0 else { return }
        defer { blockLines = 0; blockSize = nil }
        guard geometry.size(fileDescriptor: outputFileDescriptor) == blockSize else {
            // Terminals falten vorhandene Zeilen beim Resize unterschiedlich um.
            // Den alten Status einmal stehen lassen, statt mit einer inzwischen
            // ungesicherten Zeilenzahl in dauerhafte Logs zurückzuspringen.
            print("\r", terminator: "")
            return
        }
        print(String(repeating: "\u{001B}[1A\u{001B}[2K", count: blockLines), terminator: "\u{001B}[G")
    }

    func emitLog(_ line: String) {
        clearBlock()
        print(line)
    }

    func drawBlock(_ text: String) {
        guard let geometry else {
            let status = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            if !status.isEmpty, status != lastPlainStatus {
                print(status)
                lastPlainStatus = status
            }
            return
        }
        clearBlock()
        let size = geometry.size(fileDescriptor: outputFileDescriptor)
        guard size.columns > 2, size.rows > 1 else {
            // In ein bis zwei Spalten passen breite Glyphen nicht zuverlässig.
            // Anhängen bleibt auch dort sicher; Cursor-Redraw wird ausgelassen.
            print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
            return
        }
        let rows = physicalLines(text, columns: size.columns - 1)
        guard !rows.isEmpty else { return }
        let maximumRows = max(1, size.rows - 1)
        var visibleRows = Array(rows.prefix(maximumRows))
        if rows.count > maximumRows { visibleRows[maximumRows - 1] = "…" }
        print(visibleRows.joined(separator: "\n") + "\n", terminator: "")
        blockLines = visibleRows.count
        blockSize = size
    }

    private func physicalLines(_ text: String, columns: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        var logicalLines = text.components(separatedBy: "\n")
        if logicalLines.last == "" { logicalLines.removeLast() }
        var rows: [String] = []
        for line in logicalLines {
            var row = ""
            var used = 0
            for character in line {
                let safe: String
                if character == "\t" {
                    safe = String(repeating: " ", count: 8 - used % 8)
                } else if character.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
                    safe = "�"
                } else {
                    safe = String(character)
                }
                for glyph in safe {
                    let measured = max(1, characterWidth.cells(glyph))
                    let displayed = measured > columns ? "�" : glyph
                    let cells = measured > columns ? 1 : measured
                    if used + cells > columns {
                        rows.append(row)
                        row = ""
                        used = 0
                    }
                    row.append(displayed)
                    used += cells
                }
            }
            rows.append(row)
        }
        return rows
    }
}
