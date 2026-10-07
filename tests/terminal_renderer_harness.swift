import Foundation

@main
struct TerminalRendererHarness {
    struct Command: Decodable { let action: String; let text: String }

    @MainActor static func main() throws {
        let renderer = TerminalRenderer()
        while let line = readLine() {
            let command = try JSONDecoder().decode(Command.self, from: Data(line.utf8))
            switch command.action {
            case "draw": renderer.drawBlock(command.text)
            case "log": renderer.emitLog(command.text)
            case "clear": renderer.clearBlock()
            default: throw NSError(domain: "TerminalRendererHarness", code: 1)
            }
            fflush(stdout)
            FileHandle.standardError.write(Data("done\n".utf8))
        }
    }
}
