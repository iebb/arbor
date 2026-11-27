import AppKit
import CoreServices
import UniformTypeIdentifiers

/// Reads folder contents off the main thread.
enum DirectoryLoader {
    static func load(_ url: URL, showHidden: Bool) async throws -> [FileItem] {
        let hideProtected = Preferences.shared[.hideProtectedSystemFiles]
        return try await Task.detached(priority: .userInitiated) {
            let urls = try FileManager().contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: FileItem.resourceKeys,
                options: showHidden ? [] : [.skipsHiddenFiles]
            )
            return urls
                .filter { !(showHidden && hideProtected && ProtectedFiles.isProtected($0)) }
                .compactMap { FileItem(url: $0) }
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

/// "Hide protected operating system files": macOS bookkeeping files and the Unix folders at the top
/// of the startup disk stay hidden even when hidden items are shown.
enum ProtectedFiles {
    static let names: Set<String> = [
        ".DS_Store", ".localized", "Icon\r", ".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems",
        ".DocumentRevisions-V100", ".VolumeIcon.icns", ".apdisk", ".com.apple.timemachine.donotpresent",
        ".PKInstallSandboxManager-SystemSoftware", ".vol", ".file", ".nofollow", ".resolve", ".hotfiles.btree",
    ]
    static let rootNames: Set<String> = ["bin", "sbin", "usr", "private", "cores", "dev", "etc", "tmp", "var"]

    static func isProtected(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if names.contains(name) || name.hasPrefix("._") { return true }
        return url.deletingLastPathComponent().pathKey == "/" && rootNames.contains(name)
    }

    /// Folders skipped when "Include system directories" is off.
    static var systemDirectories: [String] {
        ["/System", "/Library", "/private", "/usr", "/bin", "/sbin", "/cores", "/dev",
         FileManager.default.realHomeDirectory.appendingPathComponent("Library").pathKey]
    }
}

/// Watches one folder for entries being added, removed or renamed.
/// Opens the directory descriptor off the main thread so TCC prompts or slow mounts never stall the UI.
final class DirectoryWatcher {
    var onChange: (() -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var generation = 0

    func watch(_ url: URL?) {
        stop()
        guard let url else { return }
        generation += 1
        let expected = generation
        let path = url.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == expected else {
                    close(descriptor)
                    return
                }
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
        }
    }

    func stop() {
        generation += 1
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
    let usesWildcards: Bool

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

/// What Explorer's Search tab controls.
struct SearchOptions {
    var showHidden: Bool
    var hideProtected: Bool
    var includeSystemDirectories: Bool
    var includeCompressedFiles: Bool
    var searchContents: Bool

    static var current: SearchOptions {
        let prefs = Preferences.shared
        return SearchOptions(
            showHidden: prefs.showHidden,
            hideProtected: prefs[.hideProtectedSystemFiles],
            includeSystemDirectories: prefs[.searchSystemDirectories],
            includeCompressedFiles: prefs[.searchCompressedFiles],
            searchContents: prefs[.searchFileContents]
        )
    }
}

/// Recursive search below a folder, streaming results in batches. Uses Spotlight (`MDQuery`)
/// when the folder is indexed for instant results, and falls back to filesystem enumeration
/// for unindexed locations, hidden items, or ZIP archive contents.
enum SearchService {
    static let maxContentSize = 16 * 1024 * 1024

    /// Builds a Spotlight (`MDQuery`) predicate string for Explorer's search syntax.
    static func spotlightQuery(for rawQuery: String, searchContents: Bool) -> String? {
        let matcher = NameMatcher(rawQuery)
        guard !matcher.query.isEmpty else { return nil }
        let escaped = escapeSpotlight(matcher.query, keepWildcards: matcher.usesWildcards)
        let namePattern = matcher.usesWildcards ? escaped : "*\(escaped)*"
        let nameClause = "kMDItemFSName == '\(namePattern)'cd"
        if searchContents, !matcher.usesWildcards {
            return "(\(nameClause) || kMDItemTextContent == '*\(escaped)*'cd)"
        }
        return nameClause
    }

    private static func escapeSpotlight(_ text: String, keepWildcards: Bool) -> String {
        var out = ""
        for ch in text {
            switch ch {
            case "\\", "'", "\"":
                out.append("\\")
                out.append(ch)
            case "*", "?":
                if !keepWildcards { out.append("\\") }
                out.append(ch)
            default:
                out.append(ch)
            }
        }
        return out
    }

    /// True when macOS Spotlight has metadata for this folder (excludes temp dirs and unindexed volumes).
    static func isSpotlightIndexed(_ root: URL) -> Bool {
        let path = root.standardizedFileURL.path
        if path.hasPrefix("/tmp/") || path == "/tmp" || path.hasPrefix("/private/tmp/") || path == "/private/tmp"
            || path.hasPrefix("/var/folders/") || path.hasPrefix("/private/var/folders/") {
            return false
        }
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, root as CFURL) else { return false }
        return MDItemCopyAttribute(item, kMDItemContentType) != nil
    }

    static func search(root: URL, query: String, options: SearchOptions) -> AsyncStream<[FileItem]> {
        AsyncStream { continuation in
            let flag = CancellationFlag()
            continuation.onTermination = { _ in flag.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                let matcher = NameMatcher(query)
                guard !matcher.query.isEmpty else {
                    continuation.finish()
                    return
                }
                let skipped = options.includeSystemDirectories ? [] : ProtectedFiles.systemDirectories.filter { $0 != root.pathKey }
                var seen = Set<String>()

                // Fast path: Spotlight index.
                let indexed = isSpotlightIndexed(root)
                if indexed, let predicate = spotlightQuery(for: query, searchContents: options.searchContents) {
                    runSpotlight(
                        root: root,
                        predicate: predicate,
                        options: options,
                        skipped: skipped,
                        flag: flag,
                        seen: &seen,
                        yield: { continuation.yield($0) }
                    )
                    // When Spotlight covers the whole query (no ZIP internals, no hidden dotfiles), we're done.
                    if !options.includeCompressedFiles && !options.showHidden {
                        continuation.finish()
                        return
                    }
                }

                if flag.isCancelled {
                    continuation.finish()
                    return
                }

                // Fallback / supplement: direct filesystem walk.
                var enumerationOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
                if !options.showHidden { enumerationOptions.insert(.skipsHiddenFiles) }
                let keys = FileItem.resourceKeys + [.fileSizeKey]
                guard let enumerator = FileManager().enumerator(
                    at: root,
                    includingPropertiesForKeys: keys,
                    options: enumerationOptions,
                    errorHandler: { _, _ in true }
                ) else {
                    continuation.finish()
                    return
                }
                var batch: [FileItem] = []
                var lastFlush = Date()
                while let url = enumerator.nextObject() as? URL {
                    if flag.isCancelled { break }
                    if !skipped.isEmpty, skipped.contains(url.pathKey) {
                        enumerator.skipDescendants()
                        continue
                    }
                    if options.showHidden, options.hideProtected, ProtectedFiles.isProtected(url) {
                        enumerator.skipDescendants()
                        continue
                    }
                    let key = url.pathKey
                    if seen.contains(key) { continue }
                    if matches(url, matcher: matcher, options: options), let item = FileItem(url: url) {
                        seen.insert(key)
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

    private static func runSpotlight(
        root: URL,
        predicate: String,
        options: SearchOptions,
        skipped: [String],
        flag: CancellationFlag,
        seen: inout Set<String>,
        yield: ([FileItem]) -> Void
    ) {
        guard let mdQuery = MDQueryCreate(kCFAllocatorDefault, predicate as CFString, nil, nil) else { return }
        MDQuerySetSearchScope(mdQuery, [root.path] as CFArray, 0)
        guard MDQueryExecute(mdQuery, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return }
        let count = MDQueryGetResultCount(mdQuery)
        var batch: [FileItem] = []
        var lastFlush = Date()
        for index in 0..<count {
            if flag.isCancelled { break }
            guard let raw = MDQueryGetResultAtIndex(mdQuery, index) else { continue }
            let mdItem = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(mdItem, kMDItemPath) as? String else { continue }
            let url = URL(fileURLWithPath: path)
            let key = url.pathKey
            if seen.contains(key) { continue }
            if !skipped.isEmpty, skipped.contains(where: { key == $0 || key.hasPrefix($0 + "/") }) { continue }
            if options.hideProtected, ProtectedFiles.isProtected(url) { continue }
            if !options.showHidden, isPathHidden(url, below: root) { continue }
            if let item = FileItem(url: url) {
                seen.insert(key)
                batch.append(item)
            }
            if batch.count >= 250 || (!batch.isEmpty && Date().timeIntervalSince(lastFlush) > 0.25) {
                yield(batch)
                batch = []
                lastFlush = Date()
            }
        }
        if !batch.isEmpty { yield(batch) }
    }

    private static func isPathHidden(_ url: URL, below root: URL) -> Bool {
        let rootKey = root.pathKey
        var cursor = url
        while cursor.pathKey != rootKey && cursor.pathKey != "/" {
            if cursor.lastPathComponent.hasPrefix(".") { return true }
            if (try? cursor.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true { return true }
            cursor = cursor.deletingLastPathComponent()
        }
        return false
    }

    private static func matches(_ url: URL, matcher: NameMatcher, options: SearchOptions) -> Bool {
        if matcher.matches(url.lastPathComponent) { return true }
        let ext = url.pathExtension.lowercased()
        if options.includeCompressedFiles, ext == "zip" {
            return zipEntryNames(url).contains { matcher.matches(($0 as NSString).lastPathComponent) }
        }
        if options.searchContents, !matcher.usesWildcards, isSearchableText(url) {
            return fileContains(url, text: matcher.query)
        }
        return false
    }

    static func isSearchableText(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= maxContentSize else { return false }
        guard let type = values.contentType else { return false }
        return type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml)
    }

    static func fileContains(_ url: URL, text: String) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        let content = String(decoding: data, as: UTF8.self)
        return content.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Entry names in a ZIP archive, read with the system's `zipinfo`.
    static func zipEntryNames(_ url: URL) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
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
/// Cached briefly and invalidated whenever volumes mount/unmount so breadcrumb updates never stall the main thread.
enum VolumeService {
    private static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey,
        .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey,
    ]
    private static var cached: (volumes: [VolumeInfo], at: Date)?

    static func invalidateCache() { cached = nil }

    static func mountedVolumes(forceRefresh: Bool = false) -> [VolumeInfo] {
        if !forceRefresh, let cached, Date().timeIntervalSince(cached.at) < 10 {
            return cached.volumes
        }
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else { return [] }
        let volumes: [VolumeInfo] = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsBrowsable ?? true else { return nil }
            let important = values.volumeAvailableCapacityForImportantUsage
            let available = important.map { $0 } ?? Int64(values.volumeAvailableCapacity ?? 0)
            let isRoot = values.volumeIsRootFileSystem ?? (url.pathKey == "/")
            let isNetwork = !(values.volumeIsLocal ?? true)
            var displayName = values.volumeLocalizedName ?? url.lastPathComponent
            #if DEBUG
            if DemoRedactor.enabled, !isRoot, !isNetwork { displayName = String(localized: "External SSD") }
            #endif
            return VolumeInfo(
                url: url.normalizedFolder,
                name: displayName,
                totalCapacity: Int64(values.volumeTotalCapacity ?? 0),
                availableCapacity: available,
                isRoot: isRoot,
                isEjectable: (values.volumeIsEjectable ?? false) || (values.volumeIsRemovable ?? false),
                isNetwork: isNetwork
            )
        }
        let sorted = volumes.sorted { a, b in
            if a.isRoot != b.isRoot { return a.isRoot }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        cached = (sorted, Date())
        return sorted
    }

    /// Drives shown on This Mac and in the tree. "Hide empty drives" hides removable drives with nothing on them.
    static func visibleVolumes() -> [VolumeInfo] {
        let volumes = mountedVolumes(forceRefresh: true)
        guard Preferences.shared[.hideEmptyDrives] else { return volumes }
        return volumes.filter { volume in
            guard volume.isEjectable else { return true }
            let entries = (try? FileManager.default.contentsOfDirectory(at: volume.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return !entries.isEmpty
        }
    }

    static func volume(containing url: URL, in volumes: [VolumeInfo]) -> VolumeInfo? {
        volumes
            .filter { url.isSameItem(as: $0.url) || url.isDescendant(of: $0.url) }
            .max { $0.url.pathKey.count < $1.url.pathKey.count }
    }
}

/// File icons and Quick Look thumbnails, cached.
/// `fastIcon(for:)` returns immediately without disk I/O; `loadIcon(for:completion:)` resolves the exact file icon asynchronously.
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()
    private static let typeCache = NSCache<NSString, NSImage>()
    private static let queue = DispatchQueue(label: "io.github.iebb.arbor.icons", qos: .userInitiated)

    static func icon(for url: URL) -> NSImage {
        let key = url.pathKey as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = resolveIcon(for: url)
        cache.setObject(image, forKey: key)
        return image
    }

    static func cachedIcon(for url: URL) -> NSImage? {
        cache.object(forKey: url.pathKey as NSString)
    }

    /// Instant zero-disk-I/O placeholder icon based on the item's UTType (or cached exact icon if ready).
    static func fastIcon(for item: FileItem) -> NSImage {
        if let cached = cachedIcon(for: item.url) { return cached }
        let type: UTType = item.isFolder ? .folder : (item.contentType ?? .data)
        let typeKey = type.identifier as NSString
        if let cached = typeCache.object(forKey: typeKey) { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        typeCache.setObject(image, forKey: typeKey)
        return image
    }

    /// Resolves the exact file icon off the main thread and delivers it on the main queue.
    static func loadIcon(for url: URL, completion: @escaping (NSImage) -> Void) {
        let key = url.pathKey as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }
        queue.async {
            let image = resolveIcon(for: url)
            cache.setObject(image, forKey: key)
            DispatchQueue.main.async { completion(image) }
        }
    }

    private static func resolveIcon(for url: URL) -> NSImage {
        if let docs = FileManager.default.userFolderURL(.documentDirectory),
           url.isSameItem(as: docs),
           let clean = NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/DocumentsFolderIcon.icns") {
            return clean
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func invalidate() {
        cache.removeAllObjects()
        typeCache.removeAllObjects()
    }
}
