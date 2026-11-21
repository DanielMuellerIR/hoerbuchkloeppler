import HoerbuchkloepplerCore
import SwiftUI

struct ChapterListView: View {
    @ObservedObject var session: ConversionSession
    @ObservedObject var preview: ChapterPreviewPlayer
    @State private var selectedChapters: Set<UUID> = []
    @State private var renamePrefix = "Kapitel"

    var body: some View {
        if session.audioFiles.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary)
                Text("Audiodateien oder Ordner hierherziehen")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3), lineWidth: 1))
        } else {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Alle löschen") {
                        preview.stop()
                        selectedChapters.removeAll()
                        session.removeAllChapters()
                    }
                    .foregroundStyle(.red)
                    .buttonStyle(.bordered)
                }
                .padding([.top, .horizontal])
                editControls
                List(selection: $selectedChapters) {
                    ForEach(session.audioFiles) { file in
                        chapterRow(file).tag(file.id)
                    }
                    .onMove { offsets, destination in session.moveChapters(from: offsets, to: destination) }
                }
            }
            .disabled(session.isImporting)
        }
    }

    private var editControls: some View {
        HStack {
            TextField("Titelpräfix", text: $renamePrefix).frame(width: 120)
            Button("Auswahl nummerieren") { session.renameChapters(ids: selectedChapters, prefix: renamePrefix) }
                .disabled(selectedChapters.isEmpty)
            Button("↑") { moveSelection(by: -1) }
                .accessibilityLabel("Kapitel nach oben")
                .disabled(selectedChapters.count != 1)
            Button("↓") { moveSelection(by: 1) }
                .accessibilityLabel("Kapitel nach unten")
                .disabled(selectedChapters.count != 1)
            Button("Teilen") {
                guard let id = preview.playingID, let time = preview.absolutePlaybackTime else { return }
                preview.stop()
                session.splitChapter(id: id, at: time)
            }
            .disabled(!preview.canSplit)
            .help("Kapitel an der aktuellen Abspielposition teilen")
            Button("Zusammenführen") {
                guard let id = selectedChapters.first else { return }
                preview.stop()
                session.mergeChapterWithNext(id: id)
            }
            .disabled(!canMergeSelectedChapter)
            .help("Mit dem unmittelbar folgenden Zeitabschnitt derselben Quelle zusammenführen")
        }
        .padding(.horizontal)
    }

    private func chapterRow(_ file: AudioFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "music.note").foregroundStyle(Color.accentColor).frame(width: 20)
                TextField("Kapiteltitel", text: Binding(
                    get: { session.audioFiles.first(where: { $0.id == file.id })?.chapterTitle ?? file.chapterTitle },
                    set: { session.renameChapter(id: file.id, title: $0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(formatDuration(file.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help("Kapiteldauer")
                Button(action: { preview.toggle(file) }) {
                    Image(systemName: preview.playingID == file.id ? "pause.circle.fill" : "play.circle")
                        .foregroundStyle(.green)
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .help("Kapitel anhören")
                .accessibilityLabel(preview.playingID == file.id ? "Wiedergabe anhalten" : "Kapitel anhören")
                Button(action: { session.fetchRawMediaInfo(for: file) }) {
                    Image(systemName: "info.circle").foregroundStyle(.blue).frame(width: 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Datei-Details")
                Button {
                    if preview.playingID == file.id { preview.stop() }
                    session.removeChapter(id: file.id)
                } label: {
                    Image(systemName: "trash").foregroundStyle(.red).frame(width: 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Kapitel löschen")
            }
            Text(file.name).font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 30)
        }
        .padding(.vertical, 4)
    }

    private var canMergeSelectedChapter: Bool {
        guard selectedChapters.count == 1, let id = selectedChapters.first else { return false }
        return session.canMergeChapterWithNext(id: id)
    }

    private func moveSelection(by offset: Int) {
        guard let id = selectedChapters.first,
              let index = session.audioFiles.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard session.audioFiles.indices.contains(target) else { return }
        session.moveChapters(from: IndexSet(integer: index), to: offset > 0 ? target + 1 : target)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
