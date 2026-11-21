import HoerbuchkloepplerCore
import SwiftUI

struct ConversionOverlayView: View {
    @ObservedObject var session: ConversionSession
    
    var body: some View {
        ZStack {
            VisualEffectView(material: .fullScreenUI, blendingMode: .withinWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Konvertierungsprotokoll").font(.headline)
                            Text(session.conversionPhase)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(session.logString, forType: .string)
                        } label: {
                            Label("Protokoll kopieren", systemImage: "doc.on.doc")
                        }
                        .disabled(session.logString.isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .windowBackgroundColor))

                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                LogTranscriptView(entries: session.eventLogs)
                                    .equatable()
                                    .padding(.horizontal, 16)

                                if session.isConverting && !session.segmentProgress.isEmpty {
                                    segmentProgress
                                }

                                Color.clear.frame(height: 1).id("log-end")
                            }
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        }
                        .onChange(of: session.eventLogs.count) { _ in
                            withAnimation { proxy.scrollTo("log-end", anchor: .bottom) }
                        }
                        .onChange(of: session.segmentProgress.count) { _ in
                            withAnimation { proxy.scrollTo("log-end", anchor: .bottom) }
                        }
                    }
                    .background(.black)
                }
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.3), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.6), radius: 20, x: 0, y: 10)
                .frame(maxWidth: 800, maxHeight: 550)

                VStack(alignment: .leading) {
                    ProgressView("Gesamtfortschritt", value: session.progress)
                    if !session.isConverting {
                        Text(session.lastConversionSucceeded == true ? "Alle Ausgaben erfolgreich" : (session.completedOutputURLs.isEmpty ? "Keine erfolgreiche Ausgabe" : "Teilerfolg: Einige Ausgaben wurden erstellt"))
                        // Bei einem Auto-Split entstehen leicht ein Dutzend
                        // Einträge. Ohne eigenen Rahmen drängten sie den
                        // „Schließen"-Knopf aus dem Fenster — und das Overlay
                        // hat keinen zweiten Ausweg.
                        ScrollView {
                            VStack(alignment: .leading) {
                                ForEach(session.completedOutputURLs, id: \.self) { url in
                                    Button("Im Finder zeigen: \(url.lastPathComponent)") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 120)
                    }
                }.frame(maxWidth: 800).padding(.top)
                HStack {
                    Spacer()
                    if session.isConverting {
                        Button("Vorgang abbrechen") { FFmpegWrapper.cancelConversion(session: session) }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                            .controlSize(.large)
                    } else {
                        Button("Schließen") { session.forceCloseOverlay() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                }
                .padding(.top, 20)
            }
            .padding(30)
            .padding(.bottom, 8)
        }
    }

    private var segmentProgress: some View {
        let segments = session.segmentProgress.sorted { $0.key < $1.key }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Segmentfortschritt")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: .systemYellow))
                .padding(.top, 10)
            if segments.contains(where: { PacmanBar(progress: $0.value.progress).isAnimating }) {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let mouthOpen = Int(context.date.timeIntervalSinceReferenceDate * 4).isMultiple(of: 2)
                    segmentRows(segments, mouthOpen: mouthOpen)
                }
            } else {
                segmentRows(segments, mouthOpen: true)
            }
        }
        .padding(.horizontal, 16)
    }

    private func segmentRows(_ segments: [(key: Int, value: SegmentStatus)], mouthOpen: Bool) -> some View {
        ForEach(segments, id: \.key) { index, status in
            let bar = PacmanBar(progress: status.progress)
            PacmanRow(index: index + 1, filename: status.filename, bar: bar,
                      mouthOpen: !bar.isAnimating || mouthOpen)
                .equatable()
        }
    }
}

/// Zeigt den Logverlauf als EIGENE, vergleichbare View.
///
/// Das Overlay beobachtet die gesamte Session: Jedes Fortschritts-Ereignis des
/// Workers (mehrfach pro Sekunde je Segment) wertet dessen `body` neu aus.
/// Stünde der Textaufbau dort, würde bei jedem Tick der komplette Logbestand
/// erneut in einen `AttributedString` geschrieben — auf dem Main Actor und mit
/// wachsender Laufzeit. `ConversionSession.addLog` vermeidet dieselbe
/// quadratische Arbeit bereits für `logString`.
///
/// Über `.equatable()` entscheidet SwiftUI anhand von `==`, ob der Text
/// überhaupt neu gebaut werden muss. Einträge werden nur angehängt oder die
/// Liste komplett geleert; Anzahl plus letzte Kennung erkennen beides.
private struct LogTranscriptView: View, Equatable {
    let entries: [LogEntry]

    /// Ein DateFormatter ist teuer im Aufbau und hier zustandslos.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()

    static func == (lhs: LogTranscriptView, rhs: LogTranscriptView) -> Bool {
        lhs.entries.count == rhs.entries.count
            && lhs.entries.last?.id == rhs.entries.last?.id
    }

    var body: some View {
        Text(Self.buildLogAttributedString(entries))
    }

    static func buildLogAttributedString(_ entries: [LogEntry]) -> AttributedString {
        var attrStr = AttributedString()

        for entry in entries {
            // Time
            var timeStr = AttributedString(timeFormatter.string(from: entry.date) + "  ")
            timeStr.font = .system(size: 11, design: .monospaced)
            timeStr.foregroundColor = .gray

            // Message
            var msgStr = AttributedString(entry.message + "\n")
            msgStr.font = .system(size: 12, design: .monospaced)
            // Use SwiftUI Colors
            switch entry.type {
            case .highlight:
                msgStr.foregroundColor = Color(NSColor.systemCyan)
            case .info:
                msgStr.foregroundColor = Color(NSColor.systemGreen)
            case .dim:
                msgStr.foregroundColor = Color(NSColor.darkGray).opacity(0.8)
            case .warning:
                msgStr.foregroundColor = Color(nsColor: .systemOrange)
            case .error:
                msgStr.foregroundColor = Color(nsColor: .systemRed)
            }

            attrStr.append(timeStr)
            attrStr.append(msgStr)
        }
        return attrStr
    }
}

struct PacmanBar: Equatable {
    let progress: Double
    var isAnimating: Bool { progress > 0 && progress < 1 }
    var percentage: Int { Int(progress * 100) }

    init(progress: Double) {
        self.progress = progress.isFinite ? min(1, max(0, progress)) : 0
    }

    func text(mouthOpen: Bool) -> AttributedString {
        let cells = 35
        let consumed = Int(progress * Double(cells))
        let remaining = max(0, cells - consumed - 1)
        let brackets = Color(nsColor: .darkGray)
        var opening = AttributedString("[")
        opening.foregroundColor = brackets
        var closing = AttributedString("]")
        closing.foregroundColor = brackets
        var dots = AttributedString(String(repeating: "·", count: remaining))
        dots.foregroundColor = Color(nsColor: .systemGray).opacity(0.7)
        var bar = opening
        bar.append(AttributedString(String(repeating: " ", count: consumed)))
        if consumed < cells {
            var marker = AttributedString(mouthOpen ? "C" : "O")
            marker.foregroundColor = Color(nsColor: .systemYellow)
            bar.append(marker)
            bar.append(dots)
        }
        bar.append(closing)
        return bar
    }
}

private struct PacmanRow: View, Equatable {
    let index: Int
    let filename: String
    let bar: PacmanBar
    let mouthOpen: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("CH \(String(format: "%02d", index))")
                .fontWeight(.bold)
                .foregroundStyle(Color(nsColor: .systemCyan))
                .frame(width: 45, alignment: .leading)
            Text(filename)
                .foregroundStyle(Color(nsColor: .lightGray))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(filename)
            Text(bar.text(mouthOpen: mouthOpen))
                .font(.system(size: 14, design: .monospaced))
                .fixedSize()
                .accessibilityHidden(true)
            Text("\(bar.percentage) %")
                .fontWeight(.bold)
                .foregroundStyle(Color(nsColor: bar.progress >= 1 ? .systemGreen : .systemYellow))
                .frame(width: 45, alignment: .trailing)
        }
        .font(.system(size: 12, design: .monospaced))
        .accessibilityElement(children: .combine)
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material; view.blendingMode = blendingMode; view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
