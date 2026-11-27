import AppKit

/// Explorer-style Cut / Copy / Paste of files on the system pasteboard.
///
/// File URLs go on the general pasteboard, so Finder and other apps can paste
/// copies. "Cut" is tracked here, keyed to the pasteboard's change count, so a
/// cut is forgotten as soon as anything else is copied.
final class FileClipboard {
    static let shared = FileClipboard()
    private let pasteboard = NSPasteboard.general
    private var cutChangeCount: Int?
    private var lastSeenChangeCount: Int

    private init() {
        lastSeenChangeCount = NSPasteboard.general.changeCount
    }

    private var readOptions: [NSPasteboard.ReadingOptionKey: Any] { [.urlReadingFileURLsOnly: true] }

    func write(_ urls: [URL], cut: Bool) {
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        cutChangeCount = cut ? pasteboard.changeCount : nil
        lastSeenChangeCount = pasteboard.changeCount
        postChange()
    }

    var fileURLs: [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: readOptions) as? [URL] ?? []
    }

    var hasFiles: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: readOptions)
    }

    var isCut: Bool { cutChangeCount != nil && cutChangeCount == pasteboard.changeCount }

    /// Paths of items waiting to be moved — shown dimmed, like Explorer.
    var cutPaths: Set<String> { isCut ? Set(fileURLs.map(\.pathKey)) : [] }

    /// After a cut is pasted, Explorer empties the clipboard.
    func clearAfterMove() {
        cutChangeCount = nil
        pasteboard.clearContents()
        lastSeenChangeCount = pasteboard.changeCount
        postChange()
    }

    func copyText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        cutChangeCount = nil
        lastSeenChangeCount = pasteboard.changeCount
        postChange()
    }

    /// Call when the app becomes active, to notice copies made in other apps.
    func checkForExternalChanges() {
        guard pasteboard.changeCount != lastSeenChangeCount else { return }
        lastSeenChangeCount = pasteboard.changeCount
        postChange()
    }

    private func postChange() {
        NotificationCenter.default.post(name: .arborClipboardChanged, object: self)
    }
}
