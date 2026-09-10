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
    /// Name einer Quelle, die sich nicht abspielen ließ; die Ansicht zeigt ihn
    /// als Meldung und setzt ihn zurück.
    @Published var unplayableFile: String?
    private var player: AVPlayer?
    /// Der Player, dessen Sprung an den Kapitelanfang abgeschlossen ist.
    private var seekedPlayer: AVPlayer?
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
        // Am Kapitel-Ende Icon/Status zurücksetzen — aber nur, wenn immer noch
        // dieses Kapitel läuft. `removeObserver` holt einen bereits auf `.main`
        // eingereihten Block nicht mehr zurück; ohne die Identitätsprüfung
        // stoppte das Ende von Kapitel A das gerade gestartete Kapitel B.
        let startedID = file.id
        endObserver.replace(with: NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard self?.playingID == startedID else { return }
                self?.stop()
            }
        })
        player = p
        playingID = file.id
        seekedPlayer = nil
        Task {
            // Eine gelöschte, umbenannte oder auf einem ausgehängten Volume
            // liegende Quelle spielt nie ab und meldet auch kein Ende. Ohne
            // diese Prüfung bliebe das Icon dauerhaft auf „läuft".
            let playable = (try? await AVURLAsset(url: file.url).load(.isPlayable)) ?? false
            guard player === p else { return }
            guard playable else {
                stop()
                unplayableFile = file.sourceURL.lastPathComponent
                return
            }
            await p.seek(to: CMTime(seconds: file.startTime, preferredTimescale: 600))
            guard player === p else { return }
            seekedPlayer = p
            p.play()
        }
    }

    /// Erst nach dem Sprung an den Kapitelanfang ist die Abspielposition
    /// aussagekräftig. Vorher lieferte sie 0, und ein „Teilen" auf einem
    /// inneren m4b-Kapitel rechnete gegen dessen Startzeit ins Negative.
    var absolutePlaybackTime: Double? {
        guard let player, player === seekedPlayer else { return nil }
        return player.currentTime().seconds
    }

    func stop() {
        player?.pause()
        player = nil
        seekedPlayer = nil
        endObserver.replace(with: nil)
        if playingID != nil { playingID = nil }
    }
}

