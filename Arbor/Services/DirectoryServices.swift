import AppKit

/// Reads folder contents off the main thread.
enum DirectoryLoader {
    static func load(_ url: URL, showHidden: Bool) async throws -> [FileItem] {
        try await Task.detached(priority: .userInitiated) {
            let urls = try FileManager().contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: FileItem.resourceKeys,
                options: showHidden ? [] : [.skipsHiddenFiles]
            )
            return urls.compactMap { FileItem(url: $0) }
        }.value
    }

    /// Child folders only, sorted naturally — what the navigation tree shows.
    static func subfolders(of url: URL, showHidden: Bool) async -> [FileItem] {
        let items = (try? await load(url, showHidden: showHidden)) ?? []
        return items
            .filter(\.isFolder)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Watches one folder for entries being added, removed or renamed.
final class DirectoryWatcher {
    var onChange: (() -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    func watch(_ url: URL?) {
        stop()
        guard let url else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .link, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleChange() }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    deinit { source?.cancel() }
}

/// A thread-safe cancellation flag for background work.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Matches file names the way Explorer's search box does: substring, or wildcards (`*.txt`, `IMG_???.jpg`).
struct NameMatcher {
    let query: String
    private let usesWildcards: Bool

    init(_ query: String) {
        self.query = query.trimmingCharacters(in: .whitespaces)
        usesWildcards = query.contains("*") || query.contains("?")
    }

    func matches(_ name: String) -> Bool {
        guard !query.isEmpty else { return false }
        if usesWildcards {
            return fnmatch(query, name, FNM_CASEFOLD) == 0
        }
        return name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// Recursive name search below a folder, streaming results in batches.
enum SearchService {
    static func search(root: URL, query: String, showHidden: Bool) -> AsyncStream<[FileItem]> {
        AsyncStream { continuation in
            let flag = CancellationFlag()
            continuation.onTermination = { _ in flag.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                let matcher = NameMatcher(query)
                var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
                if !showHidden { options.insert(.skipsHiddenFiles) }
                guard let enumerator = FileManager().enumerator(
                    at: root,
                    includingPropertiesForKeys: FileItem.resourceKeys,
                    options: options,
                    errorHandler: { _, _ in true }
                ) else {
                    continuation.finish()
                    return
                }
                var batch: [FileItem] = []
                var lastFlush = Date()
                while let url = enumerator.nextObject() as? URL {
                    if flag.isCancelled { break }
                    if matcher.matches(url.lastPathComponent), let item = FileItem(url: url) {
                        batch.append(item)
                    }
                    if !batch.isEmpty, batch.count >= 250 || Date().timeIntervalSince(lastFlush) > 0.3 {
                        continuation.yield(batch)
                        batch = []
                        lastFlush = Date()
                    }
                }
                if !batch.isEmpty { continuation.yield(batch) }
                continuation.finish()
            }
        }
    }
}

struct VolumeInfo: Hashable {
    let url: URL
    let name: String
    let totalCapacity: Int64
    let availableCapacity: Int64
    let isRoot: Bool
    let isEjectable: Bool
    let isNetwork: Bool

    var usedFraction: Double {
        guard totalCapacity > 0 else { return 0 }
        return Double(totalCapacity - availableCapacity) / Double(totalCapacity)
    }
}

/// Mounted drives — the "Devices and drives" section of This Mac.
enum VolumeService {
    private static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey,
        .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey,
    ]

    static func mountedVolumes() -> [VolumeInfo] {
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else { return [] }
        let volumes: [VolumeInfo] = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsBrowsable ?? true else { return nil }
            let important = values.volumeAvailableCapacityForImportantUsage
            let available = important.map { $0 } ?? Int64(values.volumeAvailableCapacity ?? 0)
            return VolumeInfo(
                url: url.normalizedFolder,
                name: values.volumeLocalizedName ?? url.lastPathComponent,
                totalCapacity: Int64(values.volumeTotalCapacity ?? 0),
                availableCapacity: available,
                isRoot: values.volumeIsRootFileSystem ?? (url.pathKey == "/"),
                isEjectable: (values.volumeIsEjectable ?? false) || (values.volumeIsRemovable ?? false),
                isNetwork: !(values.volumeIsLocal ?? true)
            )
        }
        return volumes.sorted { a, b in
            if a.isRoot != b.isRoot { return a.isRoot }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func volume(containing url: URL, in volumes: [VolumeInfo]) -> VolumeInfo? {
        volumes
            .filter { url.isSameItem(as: $0.url) || url.isDescendant(of: $0.url) }
            .max { $0.url.pathKey.count < $1.url.pathKey.count }
    }
}

/// File icons and Quick Look thumbnails, cached.
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL) -> NSImage {
        let key = url.pathKey as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: key)
        return image
    }

    static func invalidate() { cache.removeAllObjects() }
}
