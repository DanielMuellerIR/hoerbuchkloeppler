import Foundation
import Darwin

// Ausgabeplanung und Snapshot-Prüfung, gemeinsam für CLI und GUI.
public struct ConversionPlan: Sendable {
    public let groups: [[AudioFile]]
    public let outputURLs: [URL]
    let outputSnapshots: [OutputDestinationSnapshot]
    let outputDirectorySnapshots: [OutputDestinationSnapshot]
    let inputSnapshots: [String: OutputDestinationSnapshot]

    /// Ziele, deren Verzeichniseintrag bei der Planung bereits existierte.
    /// Anders als `FileManager.fileExists` folgt diese Auskunft Symlinks nicht;
    /// deshalb verlangt auch ein gebrochener Ziel-Symlink eine Bestätigung.
    public var outputURLsRequiringOverwriteConfirmation: [URL] {
        zip(outputURLs, outputSnapshots).compactMap { url, snapshot in
            if case .missing = snapshot { return nil }
            return url
        }
    }
}

extension FFmpegWrapper {
    public static func makeConversionPlan(files: [AudioFile], outputURL: URL, maxDurationHours: Int?) -> ConversionPlan {
        let groups = splitAudioFilesIfNeeded(files, maxDurationHours: maxDurationHours)
        let outputs = groups.indices.map {
            resolveOutputURL(outputURL, groupIndex: $0, splitGroupsCount: groups.count)
        }
        let inputSnapshots = Dictionary(
            files.map {
                let key = canonicalPath($0.url)
                return (key, captureSnapshot(of: $0.url, followSymlink: true))
            },
            uniquingKeysWith: { first, _ in first }
        )
        return ConversionPlan(
            groups: groups,
            outputURLs: outputs,
            outputSnapshots: outputs.map { captureSnapshot(of: $0) },
            outputDirectorySnapshots: outputs.map {
                captureSnapshot(
                    of: $0.deletingLastPathComponent(),
                    followSymlink: true
                )
            },
            inputSnapshots: inputSnapshots
        )
    }

    /// Der Zielname allein reicht bei einer anfangs fehlenden Ausgabedatei
    /// nicht: Ein Dateisynchronisierer kann den Elternordner zwischen Planung
    /// und Konvertierung austauschen. Verzeichnisgröße und Zeitstempel ändern
    /// sich regulär; Volume und Inode binden dagegen den ausgewählten Ordner.
    static func validateOutputDirectorySnapshot(
        for output: URL,
        expected: OutputDestinationSnapshot
    ) throws {
        let directory = output.deletingLastPathComponent()
        let current = captureSnapshot(of: directory, followSymlink: true)
        switch (expected, current) {
        case (.existing(let old), .existing(let new))
            where old.matchesDirectoryEntry(new):
            return
        case (_, .inaccessible(let number)):
            throw ConversionOutputError.destinationDirectoryInaccessible(
                directory,
                number
            )
        case (.inaccessible(let number), _):
            throw ConversionOutputError.destinationDirectoryInaccessible(
                directory,
                number
            )
        default:
            throw ConversionOutputError.destinationDirectoryChanged(directory)
        }
    }

    static func validateInputSnapshots(
        for files: [AudioFile],
        expected: [String: OutputDestinationSnapshot]
    ) throws {
        var checked = Set<String>()
        for file in files {
            let key = canonicalPath(file.url)
            guard checked.insert(key).inserted else { continue }
            let current = captureSnapshot(of: file.url, followSymlink: true)
            guard let planned = expected[key] else {
                throw ConversionOutputError.sourceChanged(file.sourceURL)
            }
            switch (planned, current) {
            case (.existing(let old), .existing(let new)) where old == new:
                continue
            case (_, .inaccessible(let number)):
                throw ConversionOutputError.sourceInaccessible(file.sourceURL, number)
            default:
                throw ConversionOutputError.sourceChanged(file.sourceURL)
            }
        }
    }

    static func validateConversionPlan(_ plan: ConversionPlan) throws {
        guard plan.groups.count == plan.outputURLs.count,
              plan.outputURLs.count == plan.outputSnapshots.count,
              plan.outputURLs.count == plan.outputDirectorySnapshots.count,
              !plan.groups.isEmpty,
              plan.groups.allSatisfy({ !$0.isEmpty }) else {
            throw ConversionOutputError.destinationChanged(
                plan.outputURLs.first ?? URL(fileURLWithPath: "/")
            )
        }
        let files = plan.groups.flatMap { $0 }
        try validateInputSnapshots(for: files, expected: plan.inputSnapshots)

        let inputByPath = Dictionary(
            files.map { (canonicalPath($0.url), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let inputIdentities: [(AudioFile, FileSystemIdentity)] = files.compactMap { file in
            guard case .existing(let identity) = plan.inputSnapshots[canonicalPath(file.url)] else {
                return nil
            }
            return (file, identity)
        }
        var seenOutputs = Set<String>()

        for (index, output) in plan.outputURLs.enumerated() {
            try validateOutputDirectorySnapshot(
                for: output,
                expected: plan.outputDirectorySnapshots[index]
            )
            let outputPath = canonicalPath(output)
            guard seenOutputs.insert(outputPath).inserted else {
                throw ConversionOutputError.destinationChanged(output)
            }
            let planned = plan.outputSnapshots[index]
            let current = captureSnapshot(of: output)
            guard planned == current else {
                if case .inaccessible(let number) = current {
                    throw ConversionOutputError.destinationInaccessible(output, number)
                }
                throw ConversionOutputError.destinationChanged(output)
            }
            if case .inaccessible(let number) = planned {
                throw ConversionOutputError.destinationInaccessible(output, number)
            }
            if case .existing(let identity) = planned,
               identity.mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                throw ConversionOutputError.destinationIsDirectory(output)
            }
            if let input = inputByPath[outputPath] {
                throw ConversionOutputError.destinationAliasesInput(output, input.sourceURL)
            }
            if let outputIdentity = fileSystemIdentity(at: output, followSymlink: true),
               let match = inputIdentities.first(where: {
                   $0.1.device == outputIdentity.device && $0.1.inode == outputIdentity.inode
               }) {
                throw ConversionOutputError.destinationAliasesInput(output, match.0.sourceURL)
            }
        }
    }

    static func resolveOutputURL(_ url: URL, groupIndex: Int, splitGroupsCount: Int) -> URL {
        if splitGroupsCount <= 1 { return url }
        let baseName = url.deletingPathExtension().lastPathComponent
        let fileExt = url.pathExtension
        let parentDir = url.deletingLastPathComponent()
        return parentDir.appendingPathComponent("\(baseName)-\(String(format: "%02d", groupIndex + 1))").appendingPathExtension(fileExt)
    }

    static func splitAudioFilesIfNeeded(_ files: [AudioFile], maxDurationHours: Int?) -> [[AudioFile]] {
        guard let maxHours = maxDurationHours, maxHours > 0 else { return [files] }
        var result: [[AudioFile]] = []; var currentGroup: [AudioFile] = []; var currentDuration: TimeInterval = 0
        for file in files {
            if currentDuration + file.duration <= Double(maxHours) * 3600 {
                currentGroup.append(file); currentDuration += file.duration
            } else {
                if !currentGroup.isEmpty { result.append(currentGroup) }
                currentGroup = [file]; currentDuration = file.duration
            }
        }
        if !currentGroup.isEmpty { result.append(currentGroup) }
        return result
    }


}
