import Foundation
import AVFoundation
import Combine
import HoerbuchkloepplerCore

/// Hält das Observer-Token des NotificationCenters außerhalb des Main Actors.
/// Ein `@MainActor`-Objekt darf in seinem (nicht isolierten) `deinit` nicht auf
/// nicht-Sendable-Eigenschaften zugreifen; die Box dagegen meldet den Observer
/// beim eigenen Freigeben ab. Der Player ist ihr einziger Besitzer, sie stirbt
/// also genau mit ihm — auch wenn ein Fenster während laufender Vorschau
/// geschlossen wird und `stop()` nie mehr aufgerufen wird.
// `nonisolated`: Das App-Target isoliert Typen standardmäßig auf den Main
// Actor; die Box muss aber aus jedem `deinit` heraus erreichbar sein.
nonisolated private final class EndObserverToken: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    /// Meldet einen vorhandenen Observer ab und merkt sich den neuen (oder nil).
    func replace(with newToken: NSObjectProtocol?) {
        lock.lock()
        let old = token
        token = newToken
        lock.unlock()
        if let old { NotificationCenter.default.removeObserver(old) }
    }

    deinit { replace(with: nil) }
}

/// Spielt zum Reinhören genau EINEN Kapitel-Abschnitt einer Datei ab.
/// Funktioniert einheitlich für Einzeldateien (startTime 0, ganze Datei) und für
/// interne m4b-Kapitel (Abschnitt [startTime, startTime+duration] der großen Datei).
/// Es läuft immer nur ein Preview gleichzeitig.
@MainActor
final class ChapterPreviewPlayer: ObservableObject {
    @Published var playingID: AudioFile.ID?
    private var player: AVPlayer?
    private let endObserver = EndObserverToken()

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
        endObserver.replace(with: NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        })
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
        endObserver.replace(with: nil)
        if playingID != nil { playingID = nil }
    }
}

