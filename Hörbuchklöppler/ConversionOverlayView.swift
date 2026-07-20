import HoerbuchkloepplerCore
import SwiftUI
import Combine

struct ConversionOverlayView: View {
    @ObservedObject var session: ConversionSession
    
    var body: some View {
        ZStack {
            // Darker blur background
            VisualEffectView(material: .fullScreenUI, blendingMode: .withinWindow)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 0) {
                // TERMINAL WINDOW
                VStack(spacing: 0) {
                    // TERMINAL HEADER (macOS style)
                    HStack {
                        HStack(spacing: 6) {
                            Circle().fill(Color.red).frame(width: 12, height: 12)
                            Circle().fill(Color.yellow).frame(width: 12, height: 12)
                            Circle().fill(Color.green).frame(width: 12, height: 12)
                        }
                        Spacer()
                        Text("hb_kloeppler — zsh")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(NSColor.lightGray))
                        Spacer()
                        // Copy Log Button
                        Button(action: {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(session.logString, forType: .string)
                        }) {
                            Image(systemName: "doc.on.doc")
                                .foregroundColor(.gray)
                        }
                        .buttonStyle(.plain)
                        .help("Gesamtes Log kopieren")
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .background(Color(NSColor.windowBackgroundColor))
                    
                    // TERMINAL BODY
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                // HISTORIE (Logs)
                                Text(buildLogAttributedString())
                                    .padding(.horizontal, 16)
                                    .textSelection(.enabled)


                                // PACMAN SEKTION (Dynamisch für parallele Tasks)
                                if session.isConverting && !session.segmentProgress.isEmpty {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text(">>> PROCESSING_SEGMENTS")
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundColor(Color(NSColor.systemYellow))
                                            .padding(.horizontal, 16)
                                            .padding(.top, 10)
                                        
                                        ForEach(session.segmentProgress.sorted(by: { $0.key < $1.key }), id: \.key) { key, status in
                                            PacmanRow(index: key + 1, filename: status.filename, progress: status.progress)
                                                .padding(.horizontal, 16)
                                        }
                                    }
                                }
                                
                                // Anchor for auto-scroll
                                Color.clear.frame(height: 1).id("BOTTOM_ANCHOR")
                            }
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled) // MACHT ALLES SELEKTIERBAR
                        }
                        .onChange(of: session.eventLogs.count) { _ in
                            withAnimation { proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom) }
                        }
                        .onChange(of: session.segmentProgress.count) { _ in
                            withAnimation { proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom) }
                        }
                    }
                    .background(Color.black)
                }
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.3), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.6), radius: 20, x: 0, y: 10)
                .frame(maxWidth: 800, maxHeight: 550) // Flexible but capped

                // ACTION BAR
                HStack {
                    Spacer()
                    if session.isConverting {
                        Button("Vorgang Abbrechen") { FFmpegWrapper.cancelConversion(session: session) }
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
    
    private func buildLogAttributedString() -> AttributedString {
        var attrStr = AttributedString()
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        
        for entry in session.eventLogs {
            // Time
            var timeStr = AttributedString(formatter.string(from: entry.date) + "  ")
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
            }
            
            attrStr.append(timeStr)
            attrStr.append(msgStr)
        }
        return attrStr
    }
}

struct PacmanRow: View {
    let index: Int
    let filename: String
    let progress: Double
    @State private var isMouthOpen = true
    
    // Ein gemeinsamer Timer für ALLE Zeilen, bewusst static: Als Instanz-`let`
    // erzeugte jeder SwiftUI-Re-Render (also jedes Fortschritts-Update) einen
    // neuen Publisher samt neuem Timer — unnötiger Timer-Churn und die
    // Mund-Animation wurde ständig zurückgesetzt.
    private static let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    
    func shortName(_ name: String, maxLength: Int = 40) -> String {
        if name.count <= maxLength { return name }
        let prefixLength = maxLength / 2 - 2
        let suffixLength = maxLength / 2 - 1
        let prefix = String(name.prefix(prefixLength))
        let suffix = String(name.suffix(suffixLength))
        return "\(prefix)...\(suffix)"
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // SPALTE 1: Index
            Text("CH \(String(format: "%02d", index))")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(Color(NSColor.systemCyan))
                .frame(width: 45, alignment: .leading)
            
            // SPALTE 2: Dateiname (nimmt verfügbaren Platz)
            Text("[\(shortName(filename))]")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(NSColor.lightGray))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
            
            // SPALTE 3: Pacman Balken
            HStack(spacing: 0) {
                let totalDots = 35
                let filledDots = min(totalDots, max(0, Int(progress * Double(totalDots))))
                
                Text("[")
                    .foregroundColor(Color(NSColor.darkGray))
                
                ForEach(0..<totalDots, id: \.self) { i in
                    if i < filledDots {
                        // Gefressener Bereich (Leerzeichen)
                        Text(" ").frame(width: 9)
                    } else if i == filledDots {
                        // Der Pacman selbst
                        Text(progress >= 1.0 ? " " : (isMouthOpen ? "ᗧ" : "○"))
                            .foregroundColor(Color(NSColor.systemYellow)).bold()
                            .frame(width: 9)
                    } else {
                        // Noch zu fressende Punkte
                        Text("•")
                            .foregroundColor(Color(NSColor.systemGray)).opacity(0.5)
                            .frame(width: 9)
                    }
                }
                
                Text("]")
                    .foregroundColor(Color(NSColor.darkGray))
            }
            .font(.system(size: 14, design: .monospaced))
            .onReceive(Self.timer) { _ in
                if progress > 0.0 && progress < 1.0 {
                    isMouthOpen.toggle()
                } else {
                    isMouthOpen = true
                }
            }
            
            // SPALTE 4: Prozentzahl
            Text(String(format: "%3d%%", Int(progress * 100)))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(progress >= 1.0 ? Color(NSColor.systemGreen) : Color(NSColor.systemYellow))
                .frame(width: 45, alignment: .trailing)
        }
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
