import AppKit

/// What a folder view needs to know to draw items the Explorer way.
struct PresentationContext {
    var showExtensions: Bool
    var cutPaths: Set<String>
    var isSearch: Bool
    var viewMode: ViewMode
    var sort: SortOrder

    func isDimmed(_ item: FileItem) -> Bool {
        item.isHidden || cutPaths.contains(item.url.pathKey)
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
