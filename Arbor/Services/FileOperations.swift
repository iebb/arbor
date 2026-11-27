import Foundation

/// One primitive change to the file system.
enum FileOp {
    case copy(URL, URL)
    case move(URL, URL)
    case trash(URL)
    case createFolder(URL)
    case createFile(URL)
    case remove(URL)

    var itemName: String {
        switch self {
        case .copy(let url, _), .move(let url, _), .trash(let url), .createFolder(let url), .createFile(let url), .remove(let url):
            return url.lastPathComponent
        }
    }
}

/// What an applied `FileOp` actually did — enough information to undo it.
enum FileChange {
    case copied(from: URL, to: URL)
    case moved(from: URL, to: URL)
    case trashed(original: URL, trashURL: URL?)
    case created(URL)

    /// The operation that reverses this change (nil when it can't be undone).
    var inverse: FileOp? {
        switch self {
        case .copied(_, let to): return .trash(to)
        case .moved(let from, let to): return .move(to, from)
        case .trashed(let original, let trashURL): return trashURL.map { .move($0, original) }
        case .created(let url): return .trash(url)
        }
    }

    /// The item this change produced, if any (used to select pasted or created items).
    var resultURL: URL? {
        switch self {
        case .copied(_, let to), .moved(_, let to): return to
        case .created(let url): return url
        case .trashed: return nil
        }
    }

    var affectedFolders: [URL] {
        switch self {
        case .copied(let from, let to), .moved(let from, let to): return [from.parentFolder, to.parentFolder]
        case .trashed(let original, _): return [original.parentFolder]
        case .created(let url): return [url.parentFolder]
        }
    }
}

/// Applies `FileOp`s synchronously. Safe to use from any thread with its own `FileManager`.
struct FileOpEngine {
    let fileManager: FileManager

    func apply(_ op: FileOp) throws -> FileChange? {
        switch op {
        case let .copy(source, destination):
            try fileManager.copyItem(at: source, to: destination)
            return .copied(from: source, to: destination)
        case let .move(source, destination):
            let parent = destination.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parent.path) {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try fileManager.moveItem(at: source, to: destination)
            return .moved(from: source, to: destination)
        case let .trash(url):
            var resulting: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &resulting)
            return .trashed(original: url, trashURL: resulting as URL?)
        case let .createFolder(url):
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            return .created(url)
        case let .createFile(url):
            guard fileManager.createFile(atPath: url.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            return .created(url)
        case let .remove(url):
            try fileManager.removeItem(at: url)
            return nil
        }
    }
}

/// A thread-safe progress record shared between a background operation and its progress window.
final class OperationProgress: @unchecked Sendable {
    let total: Int
    private let lock = NSLock()
    private var cancelled = false
    private var completed = 0
    private var currentName = ""

    init(total: Int) { self.total = total }

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }

    func update(completed: Int, currentName: String) {
        lock.withLock {
            self.completed = completed
            self.currentName = currentName
        }
    }

    var snapshot: (completed: Int, currentName: String) {
        lock.withLock { (completed, currentName) }
    }
}
