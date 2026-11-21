import Darwin
import Foundation

struct FileIdentity: Codable, Equatable {
    let device: dev_t
    let inode: ino_t
    var statIdentity: String { "\(device):\(inode)" }

    init(_ information: stat) {
        device = information.st_dev
        inode = information.st_ino
    }
}

enum DirectoryEntry: Equatable {
    case missing
    case directory(FileIdentity)
    case other(FileIdentity)

    init(_ information: stat) {
        let identity = FileIdentity(information)
        self = information.st_mode & S_IFMT == S_IFDIR ? .directory(identity) : .other(identity)
    }
}

enum InstallError: LocalizedError {
    case invalidArguments
    case unsuitableTarget(String)
    case changed(String)
    case occupied(String)
    case previousBundleMissing
    case directoryContents
    case posix(String, Int32)

    var errorDescription: String? {
        switch self {
        case .invalidArguments: "Ungültiger Aufruf des Installationshelfers."
        case .unsuitableTarget(let path): "Installationsziel muss ein unverlinkter App-Ordner sein: \(path)"
        case .changed(let entry): "Installationsziel oder Installationseintrag wurde inzwischen verändert: \(entry)"
        case .occupied(let entry): "Installationspfad ist bereits belegt: \(entry)"
        case .previousBundleMissing: "Das vorige Bundle ist an keinem Rückzugspfad eindeutig auffindbar."
        case .directoryContents: "Verzeichnisinhalt konnte nicht sicher gelesen oder entfernt werden."
        case .posix(let operation, let code): "\(operation): \(String(cString: strerror(code)))"
        }
    }
}

final class InstallDirectory {
    typealias RenameEntry = (Int32, String, String, UInt32) throws -> Void

    private let descriptor: Int32
    private let renameEntry: RenameEntry

    init(path: String, renameEntry: @escaping RenameEntry = InstallDirectory.renameRelative) throws {
        descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw InstallError.posix(path, errno) }
        self.renameEntry = renameEntry
    }

    private init(parent: Int32, name: String) throws {
        descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw InstallError.posix(name, errno) }
        renameEntry = Self.renameRelative
    }

    deinit {
        close(descriptor)
    }

    func identity() throws -> FileIdentity {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else { throw InstallError.posix("fstat", errno) }
        return FileIdentity(information)
    }

    func entry(_ name: String) throws -> DirectoryEntry {
        var information = stat()
        if fstatat(descriptor, name, &information, AT_SYMLINK_NOFOLLOW) == 0 {
            return DirectoryEntry(information)
        }
        let code = errno
        guard code == ENOENT else { throw InstallError.posix(name, code) }
        return .missing
    }

    func require(_ name: String, toBe expected: DirectoryEntry) throws {
        guard try entry(name) == expected else { throw InstallError.changed(name) }
    }

    func create(_ name: String) throws -> FileIdentity {
        guard mkdirat(descriptor, name, 0o777) == 0 else { throw InstallError.posix(name, errno) }
        let directory = try InstallDirectory(parent: descriptor, name: name)
        let identity = try directory.identity()
        try require(name, toBe: .directory(identity))
        return identity
    }

    func move(_ source: String, to destination: String, ownedBy identity: FileIdentity) throws {
        try require(source, toBe: .directory(identity))
        try renameEntry(descriptor, source, destination, UInt32(RENAME_EXCL))
        try require(destination, toBe: .directory(identity))
    }

    func swap(_ first: String, ownedBy firstIdentity: FileIdentity,
              with second: String, ownedBy secondIdentity: FileIdentity) throws {
        try require(first, toBe: .directory(firstIdentity))
        try require(second, toBe: .directory(secondIdentity))
        try renameEntry(descriptor, first, second, UInt32(RENAME_SWAP))
        // Bei einem Konflikt kann ein Rücktausch einen inzwischen fremden Eintrag treffen.
        try require(first, toBe: .directory(secondIdentity))
        try require(second, toBe: .directory(firstIdentity))
    }

    func removeOwned(_ name: String, identity: FileIdentity) throws {
        guard try entry(name) != .missing else { return }
        let quarantine = ".hoerbuchkloeppler-cleanup-\(UUID().uuidString)"
        try move(name, to: quarantine, ownedBy: identity)
        do {
            try removeDirectory(quarantine, identity: identity, depth: 0)
        } catch {
            throw InstallError.changed(quarantine)
        }
    }

    private static func renameRelative(_ descriptor: Int32, _ source: String, _ destination: String, _ flags: UInt32) throws {
        guard renameatx_np(descriptor, source, descriptor, destination, flags) == 0 else {
            throw InstallError.posix("\(source) → \(destination)", errno)
        }
    }

    private func removeDirectory(_ name: String, identity: FileIdentity, depth: Int) throws {
        let directory = try InstallDirectory(parent: descriptor, name: name)
        guard try directory.identity() == identity else { throw InstallError.changed(name) }
        try directory.removeContents(depth: depth)
        try require(name, toBe: .directory(identity))
        guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else { throw InstallError.posix(name, errno) }
    }

    private func removeContents(depth: Int) throws {
        guard depth < 128 else { throw InstallError.directoryContents }
        for name in try names() {
            let observed = try entry(name)
            switch observed {
            case .missing:
                throw InstallError.changed(name)
            case .directory(let identity):
                try removeDirectory(name, identity: identity, depth: depth + 1)
            case .other:
                try require(name, toBe: observed)
                guard unlinkat(descriptor, name, 0) == 0 else { throw InstallError.posix(name, errno) }
            }
        }
    }

    private func names() throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw InstallError.posix("dup", errno) }
        guard let stream = fdopendir(duplicate) else {
            let code = errno
            close(duplicate)
            throw InstallError.posix("fdopendir", code)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw InstallError.posix("readdir", errno) }
                return names
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name else { throw InstallError.directoryContents }
            if name != ".", name != ".." {
                names.append(name)
            }
        }
    }
}
