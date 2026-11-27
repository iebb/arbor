import AppKit

/// The icon layouts: Extra large / Large / Medium / Small icons, List (columns) and Tiles.
final class IconGridViewController: NSViewController, ItemPresenter, NSCollectionViewDataSource, NSCollectionViewDelegate, NSTextFieldDelegate {
    weak var delegate: ItemPresenterDelegate?
    let collectionView = ExplorerCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    private var items: [FileItem] = []
    private var context = PresentationContext(showExtensions: false, cutPaths: [], isSearch: false, viewMode: .largeIcons, sort: SortOrder())
    private(set) var mode: ViewMode = .largeIcons
    private var renamingURL: URL?
    private var renameCancelled = false
    /// A reload that arrived mid-rename; applied when editing ends so the edit isn't destroyed.
    private var deferredShow: (items: [FileItem], context: PresentationContext)?

    struct Metrics {
        let iconSize: CGFloat
        let itemSize: NSSize
        let style: IconItemView.Style
        let horizontal: Bool
    }

    static func metrics(for mode: ViewMode) -> Metrics {
        switch mode {
        case .extraLargeIcons: return Metrics(iconSize: 176, itemSize: NSSize(width: 200, height: 226), style: .grid, horizontal: false)
        case .largeIcons: return Metrics(iconSize: 96, itemSize: NSSize(width: 124, height: 144), style: .grid, horizontal: false)
        case .mediumIcons: return Metrics(iconSize: 48, itemSize: NSSize(width: 96, height: 96), style: .grid, horizontal: false)
        case .smallIcons: return Metrics(iconSize: 16, itemSize: NSSize(width: 220, height: 22), style: .row, horizontal: false)
        case .list: return Metrics(iconSize: 16, itemSize: NSSize(width: 240, height: 22), style: .row, horizontal: true)
        case .tiles: return Metrics(iconSize: 48, itemSize: NSSize(width: 280, height: 64), style: .tile, horizontal: false)
        case .details: return Metrics(iconSize: 16, itemSize: NSSize(width: 220, height: 22), style: .row, horizontal: false)
        }
    }

    override func loadView() {
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.controlBackgroundColor]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(IconItem.self, forItemWithIdentifier: IconItem.identifier)
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic, .link], forLocal: false)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic, .link], forLocal: true)
        collectionView.onDoubleClick = { [weak self] indexPath in
            guard let self, self.items.indices.contains(indexPath.item) else { return }
            let selection = self.selectedItems
            self.delegate?.presenter(self, open: selection.isEmpty ? [self.items[indexPath.item]] : selection)
        }
        collectionView.menuProvider = { [weak self] in
            guard let self else { return nil }
            return self.delegate?.presenter(self, menuFor: self.selectedItems)
        }
        collectionView.typeSelectHandler = { [weak self] prefix in self?.typeSelect(prefix) }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        view = scroll
        apply(mode)
    }

    func setMode(_ newMode: ViewMode) {
        guard newMode != mode || !isViewLoaded else { return }
        mode = newMode
        if isViewLoaded { apply(newMode) }
    }

    private func apply(_ mode: ViewMode) {
        let metrics = Self.metrics(for: mode)
        layout.itemSize = metrics.itemSize
        layout.scrollDirection = metrics.horizontal ? .horizontal : .vertical
        collectionView.reloadData()
    }

    // MARK: ItemPresenter

    var keyView: NSView { collectionView }

    var selectedItems: [FileItem] {
        collectionView.selectionIndexPaths
            .map(\.item)
            .sorted()
            .compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

    var containsFirstResponder: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder === collectionView || responder.isDescendant(of: collectionView)
    }

    func show(items newItems: [FileItem], context newContext: PresentationContext, scrollToTop: Bool) {
        if renamingURL != nil {
            deferredShow = (newItems, newContext)
            return
        }
        deferredShow = nil
        let previouslySelected = Set(selectedItems.map(\.url.pathKey))
        items = newItems
        context = newContext
        collectionView.reloadData()
        let paths = items.indices.filter { previouslySelected.contains(items[$0].url.pathKey) }.map { IndexPath(item: $0, section: 0) }
        collectionView.selectionIndexPaths = Set(paths)
        if scrollToTop { collectionView.scroll(.zero) }
    }

    func updateDecorations(_ newContext: PresentationContext) {
        context = newContext
        guard renamingURL == nil else { return }
        for case let item as IconItem in collectionView.visibleItems() {
            if let index = collectionView.indexPath(for: item)?.item, items.indices.contains(index) {
                configure(item, with: items[index])
            }
        }
    }

    func select(_ urls: Set<URL>, scroll: Bool) {
        guard renamingURL == nil else { return }  // changing selection would end the edit
        let keys = pathKeys(urls)
        let paths = Set(items.indices.filter { keys.contains(items[$0].url.pathKey) }.map { IndexPath(item: $0, section: 0) })
        collectionView.selectionIndexPaths = paths
        if scroll, let first = paths.min() { collectionView.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge) }
        delegate?.presenterSelectionDidChange(self)
    }

    func selectAllItems() {
        collectionView.selectAll(nil)
        delegate?.presenterSelectionDidChange(self)
    }

    func selectNoItems() {
        collectionView.deselectAll(nil)
        delegate?.presenterSelectionDidChange(self)
    }

    func invertSelection() {
        let all = Set(items.indices.map { IndexPath(item: $0, section: 0) })
        collectionView.selectionIndexPaths = all.subtracting(collectionView.selectionIndexPaths)
        delegate?.presenterSelectionDidChange(self)
    }

    func selectEdge(last: Bool) {
        guard !items.isEmpty else { return }
        let path = IndexPath(item: last ? items.count - 1 : 0, section: 0)
        collectionView.selectionIndexPaths = [path]
        collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        delegate?.presenterSelectionDidChange(self)
    }

    func focusContent() {
        view.window?.makeFirstResponder(collectionView)
    }

    private func typeSelect(_ prefix: String) {
        let lowered = prefix.lowercased()
        guard let index = items.firstIndex(where: { $0.displayName(showExtensions: context.showExtensions).lowercased().hasPrefix(lowered) }) else { return }
        select([items[index].url], scroll: true)
    }

    // MARK: Rename

    func beginRename(_ url: URL) {
        guard let index = items.firstIndex(where: { $0.url.isSameItem(as: url) }) else { return }
        let path = IndexPath(item: index, section: 0)
        collectionView.selectionIndexPaths = [path]
        collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        collectionView.layoutSubtreeIfNeeded()
        guard let item = collectionView.item(at: path) as? IconItem else { return }
        let field = item.itemView.titleField
        renamingURL = items[index].url
        renameCancelled = false
        field.delegate = self
        item.itemView.setEditing(true)
        view.window?.makeFirstResponder(field)
        selectBaseName(in: field, item: items[index], displayed: field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard renamingURL != nil else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            renameCancelled = true
            view.window?.makeFirstResponder(collectionView)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            view.window?.makeFirstResponder(collectionView)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let url = renamingURL else { return }
        renamingURL = nil
        (field.superview as? IconItemView)?.setEditing(false)
        guard let item = items.first(where: { $0.url.isSameItem(as: url) }) else { return }
        let original = item.displayName(showExtensions: context.showExtensions)
        let newName = field.stringValue
        if renameCancelled || newName == original || newName.trimmingCharacters(in: .whitespaces).isEmpty {
            field.stringValue = original
        } else if delegate?.presenter(self, rename: item, to: newName) != true {
            field.stringValue = original
        }
        renameCancelled = false
        if let deferred = deferredShow {
            deferredShow = nil
            show(items: deferred.items, context: deferred.context, scrollToTop: false)
        }
        // Return focus to the grid unless the user clicked into another text field.
        DispatchQueue.main.async { [weak self] in
            guard let self, !(self.view.window?.firstResponder is NSTextView) else { return }
            self.view.window?.makeFirstResponder(self.collectionView)
        }
    }

    // MARK: Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconItem.identifier, for: indexPath)
        if let iconItem = item as? IconItem, items.indices.contains(indexPath.item) {
            configure(iconItem, with: items[indexPath.item])
        }
        return item
    }

    private func configure(_ item: IconItem, with file: FileItem) {
        let metrics = Self.metrics(for: mode)
        let view = item.itemView
        view.style = metrics.style
        view.iconSize = metrics.iconSize
        view.representedURL = file.url
        view.titleField.stringValue = file.displayName(showExtensions: context.showExtensions)
        view.detailField.stringValue = file.kind
        view.secondDetailField.stringValue = file.isFolder ? "" : Format.bytes(file.size ?? 0)
        view.alphaValue = context.isDimmed(file) ? 0.5 : 1
        view.imageView.image = IconCache.icon(for: file.url)
        view.toolTip = file.name

        guard metrics.iconSize >= 48, ThumbnailProvider.wantsThumbnail(file) else { return }
        if let thumbnail = ThumbnailProvider.shared.cachedThumbnail(for: file.url, size: metrics.iconSize) {
            view.imageView.image = thumbnail
        } else {
            let scale = self.view.window?.backingScaleFactor ?? 2
            ThumbnailProvider.shared.requestThumbnail(for: file.url, size: metrics.iconSize, scale: scale) { [weak view] image in
                guard let view, view.representedURL?.isSameItem(as: file.url) == true else { return }
                view.imageView.image = image
            }
        }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        delegate?.presenterSelectionDidChange(self)
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        delegate?.presenterSelectionDidChange(self)
    }

    // MARK: Drag and drop

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        renamingURL == nil
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        items.indices.contains(indexPath.item) ? items[indexPath.item].url as NSURL : nil
    }

    private func dropTarget(_ indexPath: IndexPath, _ operation: NSCollectionView.DropOperation) -> FileItem? {
        guard operation == .on, items.indices.contains(indexPath.item), items[indexPath.item].isFolder else { return nil }
        return items[indexPath.item]
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        let target = dropTarget(proposedDropIndexPath.pointee as IndexPath, proposedDropOperation.pointee)
        if target == nil { proposedDropOperation.pointee = .before }
        return delegate?.presenter(self, dropOperationFor: draggingInfo, onto: target) ?? []
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        delegate?.presenter(self, acceptDrop: draggingInfo, onto: dropTarget(indexPath, dropOperation)) ?? false
    }
}

/// NSCollectionView with double-click to open, right-click selection and type-to-select.
final class ExplorerCollectionView: NSCollectionView {
    var onDoubleClick: ((IndexPath) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var typeSelectHandler: ((String) -> Void)?
    private var typed = ""
    private var lastTyped = Date.distantPast

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            onDoubleClick?(path)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: point) {
            if !selectionIndexPaths.contains(path) {
                selectionIndexPaths = [path]
                delegate?.collectionView?(self, didSelectItemsAt: [path])
            }
        } else if !selectionIndexPaths.isEmpty {
            let old = selectionIndexPaths
            deselectAll(nil)
            delegate?.collectionView?(self, didDeselectItemsAt: old)
        }
        window?.makeFirstResponder(self)
        return menuProvider?()
    }

    override func keyDown(with event: NSEvent) {
        // Like Explorer, an arrow key with nothing selected selects the first item.
        if selectionIndexPaths.isEmpty, [KeyCode.left, KeyCode.right, KeyCode.up, KeyCode.down].contains(event.keyCode),
           numberOfSections > 0, numberOfItems(inSection: 0) > 0 {
            let first = IndexPath(item: 0, section: 0)
            selectionIndexPaths = [first]
            scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge)
            delegate?.collectionView?(self, didSelectItemsAt: [first])
            return
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if flags.isEmpty, let characters = event.characters, let scalar = characters.unicodeScalars.first,
           CharacterSet.alphanumerics.union(.punctuationCharacters).union(.whitespaces).contains(scalar),
           !(scalar == " " && typed.isEmpty) {
            if Date().timeIntervalSince(lastTyped) > 1 { typed = "" }
            typed += characters
            lastTyped = Date()
            typeSelectHandler?(typed)
            return
        }
        super.keyDown(with: event)
    }
}

final class IconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("IconItem")
    var itemView: IconItemView { view as! IconItemView }

    override func loadView() {
        view = IconItemView(frame: NSRect(x: 0, y: 0, width: 120, height: 140))
    }

    override var isSelected: Bool {
        didSet { itemView.isSelected = isSelected }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { itemView.isHighlighted = highlightState == .forSelection || highlightState == .asDropTarget }
    }
}

/// One icon cell. Lays itself out as a grid icon, a single row, or a tile.
final class IconItemView: NSView {
    enum Style { case grid, row, tile }

    var style: Style = .grid { didSet { applyStyle(); needsLayout = true } }
    var iconSize: CGFloat = 96 { didSet { needsLayout = true } }
    var representedURL: URL?
    var isSelected = false { didSet { needsDisplay = true } }
    var isHighlighted = false { didSet { needsDisplay = true } }

    let imageView = NSImageView()
    let titleField = NSTextField(wrappingLabelWithString: "")
    let detailField = NSTextField.label("", size: 11, color: .secondaryLabelColor)
    let secondDetailField = NSTextField.label("", size: 11, color: .secondaryLabelColor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        titleField.font = .systemFont(ofSize: 12)
        titleField.isSelectable = false
        titleField.cell?.truncatesLastVisibleLine = true
        for view in [imageView, titleField, detailField, secondDetailField] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyStyle() {
        switch style {
        case .grid:
            titleField.alignment = .center
            titleField.maximumNumberOfLines = 2
            titleField.lineBreakMode = .byWordWrapping
        case .row, .tile:
            titleField.alignment = .left
            titleField.maximumNumberOfLines = 1
            titleField.lineBreakMode = .byTruncatingTail
        }
        detailField.isHidden = style != .tile
        secondDetailField.isHidden = style != .tile
    }

    func setEditing(_ editing: Bool) {
        titleField.isEditable = editing
        titleField.isSelectable = editing
        titleField.drawsBackground = editing
        titleField.backgroundColor = editing ? .textBackgroundColor : .clear
        titleField.isBordered = editing
    }

    override func layout() {
        super.layout()
        let b = bounds
        switch style {
        case .grid:
            let icon = min(iconSize, b.width - 8)
            imageView.frame = NSRect(x: (b.width - icon) / 2, y: b.height - icon - 6, width: icon, height: icon)
            titleField.frame = NSRect(x: 4, y: 2, width: b.width - 8, height: max(0, b.height - icon - 12))
        case .row:
            imageView.frame = NSRect(x: 4, y: (b.height - iconSize) / 2, width: iconSize, height: iconSize)
            titleField.frame = NSRect(x: iconSize + 10, y: (b.height - 17) / 2, width: b.width - iconSize - 14, height: 17)
        case .tile:
            imageView.frame = NSRect(x: 6, y: (b.height - iconSize) / 2, width: iconSize, height: iconSize)
            let x = iconSize + 14
            let width = b.width - x - 6
            titleField.frame = NSRect(x: x, y: b.height / 2 + 6, width: width, height: 17)
            detailField.frame = NSRect(x: x, y: b.height / 2 - 10, width: width, height: 15)
            secondDetailField.frame = NSRect(x: x, y: b.height / 2 - 25, width: width, height: 15)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || isHighlighted else { return }
        let color = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.25) : NSColor.controlAccentColor.withAlphaComponent(0.12)
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 5, yRadius: 5)
            border.lineWidth = 1
            border.stroke()
        }
    }
}
