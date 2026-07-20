import HoerbuchkloepplerCore
import SwiftUI

struct MetadataSelectionView: View {
    @ObservedObject var session: ConversionSession
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Metadaten vervollständigen")
                .font(.headline).padding(.top)
            
            Text("Wir haben verschiedene Tags gefunden. Bitte wählen Sie aus, welcher Wert verwendet werden soll.")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)

            if session.title.isEmpty {
                SelectionSection(label: "Hörbuch Titel", candidates: session.titleCandidates) { selectedValue in
                    session.title = selectedValue
                }
            }

            if session.author.isEmpty {
                SelectionSection(label: "Autor / Sprecher", candidates: session.authorCandidates) { selectedValue in
                    session.author = selectedValue
                }
            }

            Spacer()

            Button("Fertig") {
                dismiss()
            }.buttonStyle(.borderedProminent).padding().frame(maxWidth: 200)
        }
        .padding()
        .frame(width: 500, height: 600)
    }
}

struct SelectionSection: View {
    let label: String
    let candidates: [TagCandidate]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading) {
            Text(label).font(.system(size: 14, weight: .bold)).padding(.top)
            
            if candidates.isEmpty {
                Text("Keine passenden Tags gefunden").font(.caption).foregroundColor(.gray)
            } else {
                // Gruppierung nach Typ (MP4, ID3, etc.)
                let grouped = Dictionary(grouping: candidates, by: { $0.type })
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(grouped.keys.sorted(), id: \.self) { type in
                            VStack(alignment: .leading) {
                                Text(type).font(.caption2).foregroundColor(.blue).bold()
                                ForEach(grouped[type] ?? []) { candidate in
                                    HStack {
                                        Text("\(candidate.key): \(candidate.value)")
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                        Spacer()
                                        Button("Wählen") { onSelect(candidate.value) }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                    }
                                    .padding(4)
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(4)
                                }
                            }.padding(.bottom, 5)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }
}
