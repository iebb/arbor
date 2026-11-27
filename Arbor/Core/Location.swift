import Foundation

/// Where a browser tab is pointed: a folder, the "This Mac" overview, or a search.
enum Location: Hashable {
    case thisMac
    case folder(URL)
    case search(root: URL, query: String)

    var folderURL: URL? {
        if case .folder(let url) = self { return url }
        return nil
    }

    /// The folder that scopes this location (the folder itself, or the search root).
    var scopeURL: URL? {
        switch self {
        case .thisMac: return nil
        case .folder(let url): return url
        case .search(let root, _): return root
        }
    }

    var isSearch: Bool {
        if case .search = self { return true }
        return false
    }

    var isThisMac: Bool { self == .thisMac }

    /// Folder URLs in one canonical form, so `==` and history work reliably.
    var normalized: Location {
        switch self {
        case .thisMac: return .thisMac
        case .folder(let url): return .folder(url.normalizedFolder)
        case .search(let root, let query): return .search(root: root.normalizedFolder, query: query)
        }
    }

    var title: String {
        switch self {
        case .thisMac: return String(localized: "This Mac")
        case .folder(let url): return Location.displayName(of: url)
        case .search(let root, let query): return String(localized: "\(query) - Search Results in \(Location.displayName(of: root))")
        }
    }

    /// The text shown when the address bar switches to edit mode.
    var editablePath: String {
        switch self {
        case .thisMac: return String(localized: "This Mac")
        case .folder(let url): return url.pathKey
        case .search(let root, _): return root.pathKey
        }
    }

    static func displayName(of url: URL) -> String {
        #if DEBUG
        if let redacted = DemoRedactor.displayName(of: url) { return redacted }
        #endif
        return FileManager.default.displayName(atPath: url.path)
    }

    static var home: Location { .folder(FileManager.default.realHomeDirectory.normalizedFolder) }
}

#if DEBUG
/// Redacts personal usernames, external drive names, and demo paths during automated screenshot capture.
enum DemoRedactor {
    static var enabled = false
    static var demoRoot: URL?

    static func displayName(of url: URL) -> String? {
        guard enabled else { return nil }
        if url.isSameItem(as: FileManager.default.realHomeDirectory) { return "Alex" }
        if url.pathKey.hasPrefix("/Volumes/"), url.isVolumeRoot { return "External SSD" }
        return nil
    }

    static func redactPath(_ path: String) -> String {
        guard enabled else { return path }
        var result = path
        if let demoRoot {
            let rootKey = demoRoot.pathKey
            if result == rootKey || result.hasPrefix(rootKey + "/") {
                result = "/Users/alex/Workspace" + result.dropFirst(rootKey.count)
            }
            let privateKey = "/private" + rootKey
            if result == privateKey || result.hasPrefix(privateKey + "/") {
                result = "/Users/alex/Workspace" + result.dropFirst(privateKey.count)
            }
        }
        let user = NSUserName()
        if !user.isEmpty {
            result = result.replacingOccurrences(of: "/Users/\(user)", with: "/Users/alex")
        }
        return result
    }
}
#endif

extension URL {
    /// A canonical path string for comparing file URLs (no trailing slash, `.`/`..` resolved).
    var pathKey: String { standardizedFileURL.path }

    /// A canonical directory URL (always has the trailing slash).
    var normalizedFolder: URL { URL(fileURLWithPath: standardizedFileURL.path, isDirectory: true) }

    var parentFolder: URL { deletingLastPathComponent().normalizedFolder }

    /// True when `self` is strictly inside `ancestor`.
    func isDescendant(of ancestor: URL) -> Bool {
        let base = ancestor.pathKey
        let path = pathKey
        if base == "/" { return path != "/" }
        return path.hasPrefix(base + "/")
    }

    func isSameItem(as other: URL) -> Bool { pathKey == other.pathKey }

    var isVolumeRoot: Bool {
        if pathKey == "/" { return true }
        return (try? resourceValues(forKeys: [.isVolumeKey]))?.isVolume ?? false
    }

    /// Every folder between `ancestor` (exclusive) and `self` (inclusive), outermost first.
    func folderChain(below ancestor: URL) -> [URL] {
        guard isDescendant(of: ancestor) else { return [] }
        let baseCount = ancestor.pathKey == "/" ? 1 : ancestor.standardizedFileURL.pathComponents.count
        let components = standardizedFileURL.pathComponents
        var chain: [URL] = []
        var current = ancestor.normalizedFolder
        for component in components.dropFirst(baseCount) {
            current = current.appendingPathComponent(component, isDirectory: true)
            chain.append(current)
        }
        return chain
    }
}

extension FileManager {
    /// The user's real home folder. In the sandboxed App Store build, `realHomeDirectory`
    /// points into the app's container instead, which isn't what a file manager should show.
    var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return homeDirectoryForCurrentUser
    }

    /// ~/Desktop, ~/Documents… in the real home folder (not the sandbox container).
    func userFolderURL(_ directory: SearchPathDirectory) -> URL? {
        guard let containerURL = urls(for: directory, in: .userDomainMask).first else { return nil }
        return realHomeDirectory.appendingPathComponent(containerURL.lastPathComponent, isDirectory: true)
    }
}
