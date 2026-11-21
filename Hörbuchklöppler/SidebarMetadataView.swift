import HoerbuchkloepplerAppSupport
import HoerbuchkloepplerCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarMetadataView: View {
    @ObservedObject var session: ConversionSession
    let toolStatus: ToolStatus
    let onFileDrop: (NSItemProvider) -> Void
    let showSettings: () -> Void
    private static let contentWidth: CGFloat = 250
    private static let padding: CGFloat = 16

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(spacing: 12) {
                    cover
                    metadata
                }
                .frame(width: Self.contentWidth)
                .padding(.top, Self.padding)
            }
            Button(action: showSettings) {
                Label("Einstellungen", systemImage: "gearshape")
                    .font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(.bordered)
            systemCheck
                .frame(width: Self.contentWidth)
                .padding(.bottom, Self.padding)
        }
        .frame(width: Self.contentWidth + 2 * Self.padding)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var cover: some View {
        VStack {
            ZStack {
                if let image = session.coverImage {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.gray.opacity(0.2)
                    VStack {
                        Image(systemName: "photo.on.rectangle.angled").font(.largeTitle)
                        Text("Cover hierherziehen").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 5)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                onFileDrop(provider)
                return true
            }
            if session.coverImage != nil || session.coverPath != nil {
                Button(action: session.removeCover) {
                    Label("Cover entfernen", systemImage: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .padding(.top, 5)
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            metadataField("Titel", icon: "text.alignleft", value: $session.title)
            metadataField("Autor", icon: "person", value: $session.author)
            metadataField("Genre", icon: "music.note", value: $session.genre)
            metadataField("Sprecher", icon: "mic", value: $session.narrator)
            metadataField("Reihe", icon: "books.vertical", value: $session.series)
            metadataField("Bandnummer", icon: "number", value: $session.volumeNumber)
            metadataField("Sprache", icon: "globe", value: $session.language, example: "z. B. de")
        }
        .padding(.horizontal)
    }

    private func metadataField(_ title: String, icon: String, value: Binding<String>,
                               example: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).frame(width: 16)
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
            TextField(title, text: value, prompt: Text(example ?? ""))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
        }
    }

    private var systemCheck: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("System-Check")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            toolStatusText("FFmpeg", availability: toolStatus.ffmpeg)
            toolStatusText("MediaInfo", availability: toolStatus.mediaInfo)
        }
        .font(.system(size: 10, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
    }

    private func toolStatusText(_ name: String, availability: ToolStatus.Availability) -> some View {
        Text("\(name): \(availability.text)")
            .foregroundColor(availability == .unavailable ? .red : .secondary)
    }
}
