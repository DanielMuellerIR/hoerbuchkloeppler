import ArgumentParser
import Foundation
import HoerbuchkloepplerCore

func writeStandardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func reportedFailure(_ message: String) -> ExitCode {
    writeStandardError(message)
    return .failure
}

@MainActor
struct CLIOutput {
    let format: CLIOutputFormat
    let renderer = TerminalRenderer()

    var isJSON: Bool { format == .json }
    var animatesProgress: Bool { !isJSON && renderer.isInteractive }

    func text(_ message: String) {
        if isJSON { writeStandardError(message) }
        else { print(message) }
    }

    var showsPromptInTerminal: Bool { isatty(promptStream.fileDescriptor) != 0 }

    private var promptStream: FileHandle { isJSON ? .standardError : .standardOutput }

    func prompt(_ message: String) {
        // Die Frage hat kein Zeilenende und muss vor dem Warten auf stdin
        // sichtbar sein. Der direkte Zugriff umgeht die stdout-Zeilenpufferung.
        promptStream.write(Data(message.utf8))
    }

    func log(_ message: String) {
        if isJSON { writeStandardError(message) }
        else { renderer.emitLog(message) }
    }

    func emitJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(value)
        line.append(10)
        FileHandle.standardOutput.write(line)
    }

    func drawProgress(_ state: ConversionRunState) {
        if renderer.isInteractive {
            renderer.drawBlock(TerminalArtwork.statusBlock(for: state))
        } else {
            renderer.drawBlock("Status: \(state.status)")
        }
    }
}
