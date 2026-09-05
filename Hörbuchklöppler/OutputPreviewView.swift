import SwiftUI
import HoerbuchkloepplerCore

struct OutputPreviewView: View {
    let preview: ConversionPreview
    let onCancel: () -> Void
    let onStart: () -> Void
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ausgabevorschau").font(.title2)
            Text("\(preview.chapterCount) Kapitel · \(Int(preview.duration / 3600)) h \(Int(preview.duration.truncatingRemainder(dividingBy: 3600) / 60)) min")
            ScrollView { VStack(alignment: .leading) { ForEach(preview.outputURLs, id: \.self) { Text($0.path).textSelection(.enabled) } } }.frame(maxHeight: 180)
            Text("Geschätzter Temp-Bedarf: \(bytes(preview.tempBytes)) auf \(preview.tempVolume.path)")
            Text("Geschätzte Ausgaben: \(bytes(preview.targetBytes)) auf \(preview.targetVolume.path)")
            if let available = preview.availableTempBytes { Text("Temp-Volume frei: \(bytes(available))") }
            if let available = preview.availableTargetBytes { Text("Zielvolume frei: \(bytes(available))") }
            if preview.sharesVolume { Text("Temp und Ziel teilen sich den freien Speicher; beide Bedarfe zusammen einplanen.") }
            Text("Schätzwerte; AAC-Bitrate und Zusatzdaten können die tatsächliche Größe verändern.").font(.caption)
            HStack { Spacer(); Button("Zurück", action: onCancel); Button("Starten", action: onStart).buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 660)
    }
}
