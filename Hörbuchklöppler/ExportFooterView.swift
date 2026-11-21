import SwiftUI

struct ExportFooterView: View {
    let busyMessage: String?
    let canExport: Bool
    let canOpenCLI: Bool
    let cliHelp: String
    let export: () -> Void
    let cancelWork: () -> Void
    let openCLI: () -> Void

    var body: some View {
        VStack {
            Spacer()
            if let busyMessage {
                HStack(spacing: 12) {
                    ProgressView(busyMessage).controlSize(.small)
                    Button("Abbrechen", action: cancelWork)
                }
                .frame(height: 47)
            } else {
                Button(action: export) {
                    Text("Hörbuch erzeugen").frame(width: 200, height: 35)
                }
                .keyboardShortcut("r", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canExport)
            }
            Spacer()
            HStack {
                Spacer()
                Button(action: openCLI) {
                    Text("-> CLI")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(!canOpenCLI)
                .help(cliHelp)
            }
            .padding(.trailing, 20)
            .padding(.bottom, 10)
        }
        .frame(height: 130)
    }
}
