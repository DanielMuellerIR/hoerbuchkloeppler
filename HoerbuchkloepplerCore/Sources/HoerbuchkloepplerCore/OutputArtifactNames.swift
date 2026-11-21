import Darwin
import Foundation

enum OutputArtifactNames {
    static let workDirectoryPrefix = ".HB_StagingWork_"
    static let stagingCleanupPrefix = ".HB_StagingCleanup_"
    static let displacedCleanupPrefix = ".HB_DisplacedCleanup_"
    static let directoryCleanupPrefix = ".HB_Cleanup_"
    static let recoveryCleanupPrefix = ".HB_RecoveryCleanup_"
    static let orphanDirectoryPrefixes = [
        workDirectoryPrefix, stagingCleanupPrefix, displacedCleanupPrefix, directoryCleanupPrefix,
    ]

    /// Name der älteren Staging-Dateien direkt neben dem Ziel. Die PID
    /// allein ist kein Besitznachweis. Die Bereinigung prüft auch das xattr.
    static func stagingOutputURL(
        for finalURL: URL,
        id: UUID = UUID(),
        ownerPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> URL {
        return hiddenSiblingURL(
            for: finalURL,
            marker: "partial-\(ownerPID)-\(id.uuidString)"
        )
    }

    /// Gemeinsame Ableitung aller versteckten Nachbarnamen neben einem Ziel:
    /// führender Punkt, der auf `NAME_MAX` gekürzte Basisname, der jeweilige
    /// Marker und die Endung des Ziels. Staging- und Recovery-Namen dürfen sich
    /// nur im Marker unterscheiden — sonst greifen die Sweeps daneben, die
    /// genau an diesem Aufbau erkennen, was ihnen gehört.
    private static func hiddenSiblingURL(for finalURL: URL, marker: String) -> URL {
        let parent = finalURL.deletingLastPathComponent()
        let ext = finalURL.pathExtension.isEmpty ? "m4b" : finalURL.pathExtension
        return
            parent
            .appendingPathComponent(".\(stagingBasename(for: finalURL)).\(marker)")
            .appendingPathExtension(ext)
    }

    /// Recovery-Namen liegen bewusst außerhalb des `.partial-<PID>-`-Schemas:
    /// Die Altlastenbereinigung darf einen nach Rollback-Fehler geretteten
    /// fremden Eintrag auch nach einem Neustart niemals automatisch entfernen.
    static func recoveryOutputURL(for finalURL: URL, id: UUID = UUID()) -> URL {
        return hiddenSiblingURL(for: finalURL, marker: "recovery-\(id.uuidString)")
    }

    /// Reserviert im Dateinamen Platz für Punkt, Marker, maximale PID, UUID und
    /// Endung. Die Kürzung arbeitet in UTF-8-Bytes, weil `NAME_MAX` Bytes und
    /// nicht Swift-Zeichen begrenzt.
    static func stagingBasename(for finalURL: URL) -> String {
        let original = finalURL.deletingPathExtension().lastPathComponent
        let ext = finalURL.pathExtension.isEmpty ? "m4b" : finalURL.pathExtension
        let longestSuffix = ".partial-\(Int32.max)-00000000-0000-0000-0000-000000000000"
        let reservedBytes = 1 + longestSuffix.utf8.count + 1 + ext.utf8.count
        let limit = max(1, Int(NAME_MAX) - reservedBytes)
        var result = ""
        var byteCount = 0
        for character in original {
            let characterBytes = String(character).utf8.count
            if byteCount + characterBytes > limit { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result.isEmpty ? "output" : result
    }

    /// Liest die Besitzer-PID aus einem Staging-Dateinamen
    /// (`.<basename>.partial-<pid>-<uuid>.<ext>`). Liefert `nil` für das alte
    /// Format ohne PID und für alles, was keiner Staging-Datei ähnelt.
    static func stagedOutputOwnerPID(_ url: URL) -> pid_t? {
        let stem = url.deletingPathExtension().lastPathComponent
        // Von hinten suchen: Der Zieltitel selbst darf `.partial-` enthalten
        // (z.B. `Mein.partial-Buch.m4b` ergibt `.Mein.partial-Buch.partial-<pid>-<uuid>`).
        // Nur der letzte Marker ist der von uns angehängte; eine UUID enthält nie
        // `.partial-`, der Marker steht also garantiert am richtigen Platz.
        guard let range = stem.range(of: ".partial-", options: .backwards) else { return nil }
        let suffix = stem[range.upperBound...]
        guard let dash = suffix.firstIndex(of: "-"),
            let pid = pid_t(suffix[..<dash]),
            pid > 0,
            // Der Rest muss eine vollständige UUID sein. Das schließt das alte
            // Format `.partial-<uuid>` aus, dessen erste Zifferngruppe sonst
            // als PID durchginge.
            UUID(uuidString: String(suffix[suffix.index(after: dash)...])) != nil
        else {
            return nil
        }
        return pid
    }
}
