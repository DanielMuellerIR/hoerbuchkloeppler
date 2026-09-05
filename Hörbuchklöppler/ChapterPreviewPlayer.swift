import Foundation
import AVFoundation
import Combine
import HoerbuchkloepplerCore

/// Spielt zum Reinhören genau EINEN Kapitel-Abschnitt einer Datei ab.
/// Funktioniert einheitlich für Einzeldateien (startTime 0, ganze Datei) und für
/// interne m4b-Kapitel (Abschnitt [startTime, startTime+duration] der großen Datei).
/// Es läuft immer nur ein Preview gleichzeitig.
@MainActor
final class ChapterPreviewPlayer: ObservableObject {
    @Published var playingID: AudioFile.ID?
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    /// Startet den Abschnitt, oder stoppt ihn, wenn dieses Kapitel gerade läuft.
    func toggle(_ file: AudioFile) {
        if playingID == file.id { stop(); return }
        stop()
        guard file.duration > 0 else { return }
        let item = AVPlayerItem(url: file.url)
        // Nur bis zum Kapitel-Ende spielen (absolute Zeit in der Item-Zeitachse).
        item.forwardPlaybackEndTime = CMTime(seconds: file.startTime + file.duration, preferredTimescale: 600)
        let p = AVPlayer(playerItem: item)
        // Am Kapitel-Ende Icon/Status zurücksetzen.
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        player = p
        playingID = file.id
        Task {
            await p.seek(to: CMTime(seconds: file.startTime, preferredTimescale: 600))
            guard player === p else { return }
            p.play()
        }
    }

    var absolutePlaybackTime: Double? { player?.currentTime().seconds }

    func stop() {
        player?.pause()
        player = nil
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs); endObserver = nil }
        if playingID != nil { playingID = nil }
    }
}

