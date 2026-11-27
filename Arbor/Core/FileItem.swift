import AppKit
import UniformTypeIdentifiers

/// An immutable snapshot of one file-system entry, as shown in a folder view.
///
/// Identity is the URL: two snapshots of the same file compare equal even if
/// their metadata differs, which keeps selection stable across reloads.
struct FileItem: Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isSymbolicLink: Bool
    let isAlias: Bool
    let isHidden: Bool
    let size: Int64?
    let modified: Date?
    let created: Date?
    let kind: String
    let contentType: UTType?
    /// For symlinks and Finder aliases that point at a folder: where to navigate.
    let linkedFolderURL: URL?

    static func == (lhs: FileItem, rhs: FileItem) -> Bool { lhs.url.pathKey == rhs.url.pathKey }
    func hash(into hasher: inout Hasher) { hasher.combine(url.pathKey) }

    /// Something you can navigate into (folders, volumes, links to folders) — not packages like .app.
    var isFolder: Bool { folderURL != nil }
    var folderURL: URL? { (isDirectory && !isPackage) ? url : linkedFolderURL }

    var fileExtension: String { isFolder ? "" : (name as NSString).pathExtension }

    /// Explorer hides the extension of known file types unless "File name extensions" is on.
    func displayName(showExtensions: Bool) -> String {
        guard !showExtensions, !isFolder, FileItem.isKnownExtension(fileExtension) else { return name }
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }

    /// True when the extension is hidden in `displayName(showExtensions:)`.
    func hidesExtension(showExtensions: Bool) -> Bool {
        displayName(showExtensions: showExtensions) != name
    }

    static func isKnownExtension(_ ext: String) -> Bool {
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return !type.isDynamic
    }

    var isZipArchive: Bool { fileExtension.lowercased() == "zip" }
}

extension FileItem {
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey, .isHiddenKey,
        .fileSizeKey, .contentModificationDateKey, .creationDateKey,
        .localizedTypeDescriptionKey, .contentTypeKey,
    ]
    private static let resourceKeySet = Set(resourceKeys)

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: FileItem.resourceKeySet) else { return nil }
        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        let isLink = values.isSymbolicLink ?? false
        let isAlias = (values.isAliasFile ?? false) && !isLink
        let linked = (isLink || isAlias) ? FileItem.linkedFolder(for: url, isAlias: isAlias) : nil
        let showsAsFolder = (isDirectory && !isPackage) || linked != nil
        self.init(
            url: url,
            name: url.pathKey == "/" ? "/" : url.lastPathComponent,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isSymbolicLink: isLink,
            isAlias: isAlias,
            isHidden: values.isHidden ?? false,
            size: (isDirectory || linked != nil) ? nil : values.fileSize.map(Int64.init),
            modified: values.contentModificationDate,
            created: values.creationDate,
            kind: showsAsFolder ? String(localized: "File folder") : (values.localizedTypeDescription ?? String(localized: "File")),
            contentType: values.contentType,
            linkedFolderURL: linked
        )
    }

    private static func linkedFolder(for url: URL, isAlias: Bool) -> URL? {
        let target: URL?
        if isAlias {
            target = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])
        } else {
            target = url.resolvingSymlinksInPath()
        }
        guard let resolved = target,
              let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
              values.isDirectory == true, values.isPackage != true else { return nil }
        // Keep symlink paths as typed (like /tmp); aliases must use their target.
        return isAlias ? resolved.normalizedFolder : url.normalizedFolder
    }
}
