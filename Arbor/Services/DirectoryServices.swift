import AppKit
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
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").pathKey]
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

/// Recursive search below a folder, streaming results in batches. Matches names, and optionally
/// the names of files inside ZIP archives and the text inside files.
enum SearchService {
    static let maxContentSize = 16 * 1024 * 1024

    static func search(root: URL, query: String, options: SearchOptions) -> AsyncStream<[FileItem]> {
        AsyncStream { continuation in
            let flag = CancellationFlag()
            continuation.onTermination = { _ in flag.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                let matcher = NameMatcher(query)
                var enumerationOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
                if !options.showHidden { enumerationOptions.insert(.skipsHiddenFiles) }
                let skipped = options.includeSystemDirectories ? [] : ProtectedFiles.systemDirectories.filter { $0 != root.pathKey }
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
                    if matches(url, matcher: matcher, options: options), let item = FileItem(url: url) {
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

    /// Drives shown on This Mac and in the tree. "Hide empty drives" hides removable drives with nothing on them.
    static func visibleVolumes() -> [VolumeInfo] {
        let volumes = mountedVolumes()
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
