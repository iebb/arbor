import AppKit

/// What a folder view needs to know to draw items the Explorer way.
struct PresentationContext {
    var showExtensions: Bool
    var cutPaths: Set<String>
    var isSearch: Bool
    var viewMode: ViewMode
    var sort: SortOrder
    var groupBy: GroupKey = .none
    var display = DisplayOptions()

    func isDimmed(_ item: FileItem) -> Bool {
        item.isHidden || cutPaths.contains(item.url.pathKey)
    }
}

/// Folder Options that change how items look and respond to the mouse.
struct DisplayOptions: Equatable {
    var singleClickToOpen = false
    var underlineOnlyOnHover = true
    var checkBoxes = false
    var compact = false
    var popUpDescriptions = true
    var folderTipSize = true
    var alwaysShowIcons = false
    var fileIconOnThumbnails = true

    static var current: DisplayOptions {
        let prefs = Preferences.shared
        return DisplayOptions(
            singleClickToOpen: prefs[.singleClickToOpen],
            underlineOnlyOnHover: prefs[.underlineOnlyOnHover],
            checkBoxes: prefs[.itemCheckBoxes],
            compact: prefs[.compactView],
            popUpDescriptions: prefs[.popUpDescriptions],
            folderTipSize: prefs[.folderTipSize],
            alwaysShowIcons: prefs[.alwaysShowIcons],
            fileIconOnThumbnails: prefs[.fileIconOnThumbnails]
        )
    }

    /// Single-click mode underlines titles, always or only under the pointer.
    func underlines(hovered: Bool) -> Bool {
        singleClickToOpen && (!underlineOnlyOnHover || hovered)
    }

    /// Check boxes show on selected items and the item under the pointer, like Explorer.
    func showsCheckBox(selected: Bool, hovered: Bool) -> Bool {
        checkBoxes && (selected || hovered)
    }

    func toolTip(for item: FileItem) -> String? {
        popUpDescriptions ? ItemToolTip.text(for: item, includeFolderSize: folderTipSize) : nil
    }
}

/// The text of Explorer's item pop-ups ("Type / Size / Date modified", or a folder's contents).
enum ItemToolTip {
    static func text(for item: FileItem, includeFolderSize: Bool) -> String {
        guard let folder = item.folderURL else {
            return [String(localized: "Type: \(item.kind)"), String(localized: "Size: \(Format.bytes(item.size ?? 0))"), String(localized: "Date modified: \(Format.date(item.modified))")].joined(separator: "\n")
        }
        var lines = [String(localized: "Date created: \(Format.date(item.created))")]
        if includeFolderSize, let size = folderSize(folder) {
            lines.append(size.complete ? String(localized: "Size: \(Format.bytes(size.bytes))") : String(localized: "Size: more than \(Format.bytes(size.bytes))"))
        }
        let children = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if children.isEmpty {
            lines.append(String(localized: "Empty folder"))
        } else {
            let isDir: (URL) -> Bool = { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            let folders = children.filter(isDir).map(\.lastPathComponent)
            let files = children.filter { !isDir($0) }.map(\.lastPathComponent)
            if !folders.isEmpty { lines.append(String(localized: "Folders: \(summary(folders))")) }
            if !files.isEmpty { lines.append(String(localized: "Files: \(summary(files))")) }
        }
        return lines.joined(separator: "\n")
    }

    private static func summary(_ names: [String]) -> String {
        names.count > 4 ? names.prefix(4).joined(separator: ", ") + ", …" : names.joined(separator: ", ")
    }

    /// Adds up a folder's size, giving up after a short time so the pop-up never stalls.
    static func folderSize(_ url: URL, budget: TimeInterval = 0.25) -> (bytes: Int64, complete: Bool)? {
        let started = Date()
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: { _, _ in true }) else { return nil }
        while let child = enumerator.nextObject() as? URL {
            total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            if Date().timeIntervalSince(started) > budget { return (total, false) }
        }
        return (total, true)
    }
}

/// Supplies a view's tool tip only when it's about to be shown (folder tips are costly to build).
final class LazyToolTip: NSObject, NSViewToolTipOwner {
    var provider: (() -> String?)?

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        provider?() ?? ""
    }

    func install(on view: NSView) {
        view.removeAllToolTips()
        if provider != nil { view.addToolTip(view.bounds, owner: self, userData: nil) }
    }
}

/// An item title, underlined in single-click mode (always plain text attributes, so underline never sticks).
func itemTitle(_ text: String, underline: Bool, font: NSFont, alignment: NSTextAlignment = .left, lineBreak: NSLineBreakMode = .byTruncatingTail) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    style.lineBreakMode = lineBreak
    var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
    if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
    return NSAttributedString(string: text, attributes: attributes)
}

/// Hover-to-select for single-click mode ("point to select"): selects the item under the pointer after a pause.
final class PointToSelect {
    private var pending: DispatchWorkItem?

    func schedule(_ action: @escaping () -> Void) {
        cancel()
        let work = DispatchWorkItem {
            guard NSEvent.pressedMouseButtons == 0 else { return }
            action()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

/// A view of a folder's items (Details table or icon grid). The browser talks to both the same way.
protocol ItemPresenter: NSViewController {
    var delegate: ItemPresenterDelegate? { get set }
    var selectedItems: [FileItem] { get }
    var containsFirstResponder: Bool { get }
    /// The view to forward keystrokes to (e.g. arrow keys while Quick Look is open).
    var keyView: NSView { get }

    func show(items: [FileItem], context: PresentationContext, scrollToTop: Bool)
    func updateDecorations(_ context: PresentationContext)
    func select(_ urls: Set<URL>, scroll: Bool)
    func selectAllItems()
    func selectNoItems()
    func invertSelection()
    func selectEdge(last: Bool)
    func beginRename(_ url: URL)
    func focusContent()
}

protocol ItemPresenterDelegate: AnyObject {
    func presenterSelectionDidChange(_ presenter: ItemPresenter)
    func presenter(_ presenter: ItemPresenter, open items: [FileItem])
    func presenter(_ presenter: ItemPresenter, menuFor items: [FileItem]) -> NSMenu?
    /// Returns true when the rename succeeded.
    func presenter(_ presenter: ItemPresenter, rename item: FileItem, to newName: String) -> Bool
    func presenter(_ presenter: ItemPresenter, didChangeSort sort: SortOrder)
    func presenter(_ presenter: ItemPresenter, dropOperationFor info: NSDraggingInfo, onto folder: FileItem?) -> NSDragOperation
    func presenter(_ presenter: ItemPresenter, acceptDrop info: NSDraggingInfo, onto folder: FileItem?) -> Bool
}

extension ItemPresenter {
    func pathKeys(_ urls: Set<URL>) -> Set<String> { Set(urls.map(\.pathKey)) }
}

/// Selects the editable part of a name (without the extension), like Explorer's rename.
func selectBaseName(in field: NSTextField, item: FileItem, displayed: String) {
    guard let editor = field.currentEditor() else { return }
    let ns = displayed as NSString
    var length = ns.length
    if !item.isFolder, !ns.pathExtension.isEmpty, !ns.deletingPathExtension.isEmpty {
        length = (ns.deletingPathExtension as NSString).length
    }
    editor.selectedRange = NSRange(location: 0, length: length)
}

/// Hosts whichever content view is active and shows "This folder is empty." style messages.
final class ContentHostViewController: NSViewController {
    private(set) var current: NSViewController?
    private let messageLabel = PassthroughLabel(labelWithString: "")

    var message: String? { messageLabel.isHidden ? nil : messageLabel.stringValue }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 4
        messageLabel.isHidden = true
        root.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            messageLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 64),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -60),
        ])
        view = root
    }

    func show(_ controller: NSViewController) {
        guard controller !== current else { return }
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.width, .height]
        view.addSubview(controller.view, positioned: .below, relativeTo: messageLabel)
        current = controller
    }

    func setMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = text == nil
    }
}
