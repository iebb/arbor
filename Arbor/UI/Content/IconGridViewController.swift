import AppKit

/// The icon layouts: Extra large / Large / Medium / Small icons, List (columns) and Tiles.
final class IconGridViewController: NSViewController, ItemPresenter, NSCollectionViewDataSource, NSCollectionViewDelegate, NSTextFieldDelegate {
    weak var delegate: ItemPresenterDelegate?
    let collectionView = ExplorerCollectionView()
    private let layout = NSCollectionViewFlowLayout()
    /// All items in group order (including those in collapsed groups).
    private var allItems: [FileItem] = []
    /// Currently visible items in display order; sections are consecutive runs of it.
    private var items: [FileItem] = []
    private var groups: [ItemGroup] = []
    private var collapsedGroups: Set<String> = []
    private var sectionTitles: [String] = [""]
    private var sectionTotalCounts: [Int] = [0]
    private var sectionStarts: [Int] = [0]
    private var lastContentWidth: CGFloat = 0

    private func path(_ flat: Int) -> IndexPath {
        let section = (sectionStarts.lastIndex { $0 <= flat }) ?? 0
        return IndexPath(item: flat - sectionStarts[section], section: section)
    }

    private func flat(_ path: IndexPath) -> Int {
        (sectionStarts.indices.contains(path.section) ? sectionStarts[path.section] : 0) + path.item
    }

    private func sectionCount(_ section: Int) -> Int {
        guard sectionStarts.indices.contains(section) else { return 0 }
        let end = section + 1 < sectionStarts.count ? sectionStarts[section + 1] : items.count
        return end - sectionStarts[section]
    }

    private var isGrouped: Bool { context.groupBy != .none }
    private var context = PresentationContext(showExtensions: false, cutPaths: [], isSearch: false, viewMode: .largeIcons, sort: SortOrder())
    private(set) var mode: ViewMode = .largeIcons
    private var renamingURL: URL?
    private var renameCancelled = false
    /// A reload that arrived mid-rename; applied when editing ends so the edit isn't destroyed.
    private var deferredShow: (items: [FileItem], context: PresentationContext)?
    private var hoveredIndex = -1
    private let pointToSelect = PointToSelect()

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
        case .content: return Metrics(iconSize: 32, itemSize: NSSize(width: 600, height: 56), style: .content, horizontal: false)
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
        collectionView.register(GridGroupHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: GridGroupHeader.identifier)
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic, .link], forLocal: false)
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic, .link], forLocal: true)
        collectionView.onDoubleClick = { [weak self] indexPath in
            guard let self, self.items.indices.contains(self.flat(indexPath)) else { return }
            let selection = self.selectedItems
            self.delegate?.presenter(self, open: selection.isEmpty ? [self.items[self.flat(indexPath)]] : selection)
        }
        collectionView.onMiddleClick = { [weak self] indexPath in
            guard let self, self.items.indices.contains(self.flat(indexPath)) else { return }
            let item = self.items[self.flat(indexPath)]
            if item.isFolder { self.delegate?.presenter(self, openInNewTab: [item]) }
        }
        collectionView.menuProvider = { [weak self] in
            guard let self else { return nil }
            return self.delegate?.presenter(self, menuFor: self.selectedItems)
        }
        collectionView.typeSelectHandler = { [weak self] prefix in self?.typeSelect(prefix) }
        collectionView.isSingleClickMode = { [weak self] in self?.context.display.singleClickToOpen ?? false }
        collectionView.onSingleClickOpen = { [weak self] indexPath in
            guard let self, self.items.indices.contains(self.flat(indexPath)) else { return }
            self.delegate?.presenter(self, open: [self.items[self.flat(indexPath)]])
        }
        collectionView.onHover = { [weak self] path in
            guard let self else { return }
            self.hoverChanged(path.map(self.flat) ?? -1)
        }

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
        let spacing: CGFloat = context.display.compact ? 0 : 4
        layout.minimumInteritemSpacing = spacing
        layout.minimumLineSpacing = spacing
        layout.itemSize = metrics.itemSize
        if mode == .content { layout.itemSize.width = contentRowWidth }
        layout.scrollDirection = metrics.horizontal ? .horizontal : .vertical
        layout.headerReferenceSize = isGrouped && !metrics.horizontal ? NSSize(width: 0, height: 34) : .zero
        collectionView.reloadData()
    }

    /// Content rows span the view, like Explorer's Content layout.
    private var contentRowWidth: CGFloat {
        let width = (view as? NSScrollView)?.contentSize.width ?? view.bounds.width
        return max(320, width - layout.sectionInset.left - layout.sectionInset.right)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard mode == .content, abs(contentRowWidth - lastContentWidth) > 1 else { return }
        lastContentWidth = contentRowWidth
        layout.itemSize.width = contentRowWidth
        layout.invalidateLayout()
    }

    // MARK: ItemPresenter

    var keyView: NSView { collectionView }

    var selectedItems: [FileItem] {
        collectionView.selectionIndexPaths
            .map { flat($0) }
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
        if scrollToTop || newContext.groupBy != context.groupBy {
            collapsedGroups = []
        }
        groups = FileGrouping.groups(newItems, by: newContext.groupBy)
        allItems = groups.flatMap(\.items)
        rebuildVisibleSections()
        let groupingChanged = context.groupBy != newContext.groupBy
        let compactChanged = context.display.compact != newContext.display.compact
        context = newContext
        if compactChanged || groupingChanged { apply(mode) }
        collectionView.reloadData()
        let paths = items.indices.filter { previouslySelected.contains(items[$0].url.pathKey) }.map { path($0) }
        collectionView.selectionIndexPaths = Set(paths)
        if scrollToTop { collectionView.scroll(.zero) }
    }

    // MARK: Collapsible groups

    private func rebuildVisibleSections() {
        var visible: [FileItem] = []
        var titles: [String] = []
        var counts: [Int] = []
        var starts: [Int] = []
        for group in groups {
            titles.append(group.title)
            counts.append(group.items.count)
            starts.append(visible.count)
            if !isGrouped || !collapsedGroups.contains(group.title) {
                visible.append(contentsOf: group.items)
            }
        }
        items = visible
        sectionTitles = titles.isEmpty ? [""] : titles
        sectionTotalCounts = counts.isEmpty ? [0] : counts
        sectionStarts = starts.isEmpty ? [0] : starts
    }

    private func toggleGroup(_ title: String) {
        if collapsedGroups.contains(title) {
            collapsedGroups.remove(title)
        } else {
            collapsedGroups.insert(title)
        }
        reloadGroupsPreservingSelection()
    }

    private func reloadGroupsPreservingSelection() {
        let previouslySelected = Set(selectedItems.map(\.url.pathKey))
        rebuildVisibleSections()
        collectionView.reloadData()
        let paths = items.indices.filter { previouslySelected.contains(items[$0].url.pathKey) }.map { path($0) }
        collectionView.selectionIndexPaths = Set(paths)
        delegate?.presenterSelectionDidChange(self)
    }

    private func expandGroupsContaining(_ keys: Set<String>) {
        guard isGrouped, !collapsedGroups.isEmpty else { return }
        var changed = false
        for group in groups where collapsedGroups.contains(group.title) {
            if group.items.contains(where: { keys.contains($0.url.pathKey) }) {
                collapsedGroups.remove(group.title)
                changed = true
            }
        }
        if changed {
            rebuildVisibleSections()
            collectionView.reloadData()
        }
    }

    private func groupHeaderMenu(for title: String) -> NSMenu {
        let menu = NSMenu()
        let isCollapsed = collapsedGroups.contains(title)
        let toggle = NSMenuItem(
            title: isCollapsed ? String(localized: "Expand group") : String(localized: "Collapse group"),
            action: #selector(toggleGroupFromMenu(_:)),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.representedObject = title
        menu.addItem(toggle)
        menu.addItem(.separator())
        let expandAll = NSMenuItem(title: String(localized: "Expand all groups"), action: #selector(expandAllGroups), keyEquivalent: "")
        expandAll.target = self
        expandAll.isEnabled = !collapsedGroups.isEmpty
        menu.addItem(expandAll)
        let collapseAll = NSMenuItem(title: String(localized: "Collapse all groups"), action: #selector(collapseAllGroups), keyEquivalent: "")
        collapseAll.target = self
        collapseAll.isEnabled = collapsedGroups.count < groups.count
        menu.addItem(collapseAll)
        return menu
    }

    @objc private func toggleGroupFromMenu(_ sender: NSMenuItem) {
        if let title = sender.representedObject as? String { toggleGroup(title) }
    }

    @objc private func expandAllGroups() {
        collapsedGroups = []
        reloadGroupsPreservingSelection()
    }

    @objc private func collapseAllGroups() {
        collapsedGroups = Set(groups.map(\.title))
        reloadGroupsPreservingSelection()
    }

    func updateDecorations(_ newContext: PresentationContext) {
        context = newContext
        guard renamingURL == nil else { return }
        for case let item as IconItem in collectionView.visibleItems() {
            if let index = collectionView.indexPath(for: item).map(flat), items.indices.contains(index) {
                configure(item, with: items[index])
            }
        }
    }

    // MARK: Hover

    private func hoverChanged(_ index: Int) {
        guard index != hoveredIndex else { return }
        let old = hoveredIndex
        hoveredIndex = index
        for i in [old, index] where i >= 0 {
            (collectionView.item(at: path(i)) as? IconItem)?.itemView.isHovered = i == index
        }
        guard context.display.singleClickToOpen, index >= 0, renamingURL == nil else { return pointToSelect.cancel() }
        pointToSelect.schedule { [weak self] in
            guard let self, self.hoveredIndex == index, self.renamingURL == nil, self.items.indices.contains(index) else { return }
            let target = self.path(index)
            if NSEvent.modifierFlags.contains(.command) {
                self.collectionView.selectionIndexPaths.insert(target)
            } else if self.collectionView.selectionIndexPaths != [target] {
                self.collectionView.selectionIndexPaths = [target]
            }
            self.delegate?.presenterSelectionDidChange(self)
        }
    }

    func select(_ urls: Set<URL>, scroll: Bool) {
        guard renamingURL == nil else { return }  // changing selection would end the edit
        let keys = pathKeys(urls)
        expandGroupsContaining(keys)
        let paths = Set(items.indices.filter { keys.contains(items[$0].url.pathKey) }.map { path($0) })
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
        let all = Set(items.indices.map { path($0) })
        collectionView.selectionIndexPaths = all.subtracting(collectionView.selectionIndexPaths)
        delegate?.presenterSelectionDidChange(self)
    }

    func selectEdge(last: Bool) {
        guard !items.isEmpty else { return }
        let target = path(last ? items.count - 1 : 0)
        collectionView.selectionIndexPaths = [target]
        collectionView.scrollToItems(at: [target], scrollPosition: .nearestHorizontalEdge)
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
        expandGroupsContaining([url.pathKey])
        guard let index = items.firstIndex(where: { $0.url.isSameItem(as: url) }) else { return }
        let target = path(index)
        collectionView.selectionIndexPaths = [target]
        collectionView.scrollToItems(at: [target], scrollPosition: .nearestHorizontalEdge)
        collectionView.layoutSubtreeIfNeeded()
        guard let item = collectionView.item(at: target) as? IconItem else { return }
        let field = item.itemView.titleField
        renamingURL = items[index].url
        renameCancelled = false
        pointToSelect.cancel()
        field.stringValue = items[index].displayName(showExtensions: context.showExtensions)
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

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sectionTitles.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { sectionCount(section) }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: GridGroupHeader.identifier, for: indexPath)
        if let header = header as? GridGroupHeader, sectionTitles.indices.contains(indexPath.section) {
            let title = sectionTitles[indexPath.section]
            let count = sectionTotalCounts.indices.contains(indexPath.section) ? sectionTotalCounts[indexPath.section] : sectionCount(indexPath.section)
            header.set(title: title, count: count, collapsed: collapsedGroups.contains(title))
            header.onToggle = { [weak self] in self?.toggleGroup(title) }
            header.menuProvider = { [weak self] in self?.groupHeaderMenu(for: title) }
        }
        return header
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconItem.identifier, for: indexPath)
        if let iconItem = item as? IconItem, items.indices.contains(flat(indexPath)) {
            configure(iconItem, with: items[flat(indexPath)])
        }
        return item
    }

    private func configure(_ item: IconItem, with file: FileItem) {
        let metrics = Self.metrics(for: mode)
        let view = item.itemView
        view.style = metrics.style
        view.iconSize = metrics.iconSize
        view.representedURL = file.url
        let display = context.display
        view.display = display
        view.title = file.displayName(showExtensions: context.showExtensions)
        view.detailField.stringValue = file.kind
        if metrics.style == .content {
            view.secondDetailField.stringValue = file.isFolder ? "" : String(localized: "Size: \(Format.bytes(file.size ?? 0))")
            view.dateField.stringValue = String(localized: "Date modified: \(Format.date(file.modified))")
        } else {
            view.secondDetailField.stringValue = file.isFolder ? "" : Format.bytes(file.size ?? 0)
        }
        view.alphaValue = context.isDimmed(file) ? 0.5 : 1
        view.imageView.image = IconCache.icon(for: file.url)
        view.badgeView.image = nil
        view.toolTipSource.provider = display.popUpDescriptions ? { display.toolTip(for: file) } : nil
        view.toolTipSource.install(on: view)
        view.isHovered = collectionView.indexPath(for: item).map(flat) == hoveredIndex
        item.onToggle = { [weak self, weak item] in
            guard let self, let item, let path = self.collectionView.indexPath(for: item) else { return }
            if self.collectionView.selectionIndexPaths.contains(path) {
                self.collectionView.selectionIndexPaths.remove(path)
            } else {
                self.collectionView.selectionIndexPaths.insert(path)
            }
            item.isSelected = self.collectionView.selectionIndexPaths.contains(path)
            self.delegate?.presenterSelectionDidChange(self)
        }

        // "Always show icons, never thumbnails" turns previews off; otherwise media gets a thumbnail,
        // optionally badged with the app icon ("Display file icon on thumbnails").
        guard metrics.iconSize >= 48, !display.alwaysShowIcons, ThumbnailProvider.wantsThumbnail(file) else { return }
        let badge = display.fileIconOnThumbnails ? NSWorkspace.shared.urlForApplication(toOpen: file.url).map { NSWorkspace.shared.icon(forFile: $0.path) } : nil
        if let thumbnail = ThumbnailProvider.shared.cachedThumbnail(for: file.url, size: metrics.iconSize) {
            view.imageView.image = thumbnail
            view.badgeView.image = badge
        } else {
            let scale = self.view.window?.backingScaleFactor ?? 2
            ThumbnailProvider.shared.requestThumbnail(for: file.url, size: metrics.iconSize, scale: scale) { [weak view] image in
                guard let view, view.representedURL?.isSameItem(as: file.url) == true else { return }
                view.imageView.image = image
                view.badgeView.image = badge
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
        items.indices.contains(flat(indexPath)) ? items[flat(indexPath)].url as NSURL : nil
    }

    private func dropTarget(_ indexPath: IndexPath, _ operation: NSCollectionView.DropOperation) -> FileItem? {
        guard operation == .on, items.indices.contains(flat(indexPath)), items[flat(indexPath)].isFolder else { return nil }
        return items[flat(indexPath)]
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
    var onMiddleClick: ((IndexPath) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var typeSelectHandler: ((String) -> Void)?
    var onSingleClickOpen: ((IndexPath) -> Void)?
    var onHover: ((IndexPath?) -> Void)?
    var isSingleClickMode: () -> Bool = { false }
    private var typed = ""
    private var lastTyped = Date.distantPast
    private var hoverArea: NSTrackingArea?

    override func mouseDown(with event: NSEvent) {
        let singleClickMode = isSingleClickMode()
        let start = NSEvent.mouseLocation
        let path = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        let plain = event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
        if singleClickMode {
            let end = NSEvent.mouseLocation
            if plain, event.clickCount == 1, let path, hypot(end.x - start.x, end.y - start.y) < 4 { onSingleClickOpen?(path) }
        } else if event.clickCount == 2, let path {
            onDoubleClick?(path)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            if let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
                onMiddleClick?(path)
            }
            return
        }
        super.otherMouseUp(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHover?(indexPathForItem(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil)
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
        // Like Explorer, an arrow key with nothing selected selects the first visible item.
        if selectionIndexPaths.isEmpty, [KeyCode.left, KeyCode.right, KeyCode.up, KeyCode.down].contains(event.keyCode),
           let firstSection = (0..<numberOfSections).first(where: { numberOfItems(inSection: $0) > 0 }) {
            let first = IndexPath(item: 0, section: firstSection)
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
    var onToggle: (() -> Void)? {
        get { itemView.onToggle }
        set { itemView.onToggle = newValue }
    }

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
    enum Style { case grid, row, tile, content }

    var style: Style = .grid { didSet { applyStyle(); needsLayout = true } }
    var iconSize: CGFloat = 96 { didSet { needsLayout = true } }
    var representedURL: URL?
    var isSelected = false { didSet { needsDisplay = true; updateDecorations() } }
    var isHighlighted = false { didSet { needsDisplay = true } }
    var isHovered = false { didSet { if oldValue != isHovered { updateDecorations() } } }
    var display = DisplayOptions() { didSet { updateDecorations(); if oldValue.checkBoxes != display.checkBoxes { needsLayout = true } } }
    var title = "" { didSet { updateDecorations() } }
    var onToggle: (() -> Void)?
    let toolTipSource = LazyToolTip()
    let checkBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    /// The app icon drawn on a thumbnail's corner ("Display file icon on thumbnails").
    let badgeView = NSImageView()

    let imageView = NSImageView()
    let titleField = NSTextField(wrappingLabelWithString: "")
    let detailField = NSTextField.label("", size: 11, color: .secondaryLabelColor)
    let secondDetailField = NSTextField.label("", size: 11, color: .secondaryLabelColor)
    let dateField = NSTextField.label("", size: 11, color: .secondaryLabelColor)
    private let separator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        titleField.font = .systemFont(ofSize: 12)
        titleField.isSelectable = false
        titleField.cell?.truncatesLastVisibleLine = true
        separator.boxType = .separator
        for view in [imageView, badgeView, titleField, detailField, secondDetailField, dateField, separator, checkBox] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        badgeView.imageScaling = .scaleProportionallyUpOrDown
        checkBox.target = self
        checkBox.action = #selector(toggled)
        checkBox.isHidden = true
        applyStyle()
    }

    @objc private func toggled() { onToggle?() }

    private func updateDecorations() {
        guard !titleField.isEditable else { return }
        let grid = style == .grid
        titleField.attributedStringValue = itemTitle(
            title,
            underline: display.underlines(hovered: isHovered),
            font: .systemFont(ofSize: 12),
            alignment: grid ? .center : .left,
            lineBreak: grid ? .byWordWrapping : .byTruncatingTail
        )
        checkBox.isHidden = !display.showsCheckBox(selected: isSelected, hovered: isHovered)
        checkBox.state = isSelected ? .on : .off
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyStyle() {
        switch style {
        case .grid:
            titleField.alignment = .center
            titleField.maximumNumberOfLines = 2
            titleField.lineBreakMode = .byWordWrapping
        case .row, .tile, .content:
            titleField.alignment = .left
            titleField.maximumNumberOfLines = 1
            titleField.lineBreakMode = .byTruncatingTail
        }
        detailField.isHidden = style != .tile && style != .content
        secondDetailField.isHidden = style != .tile && style != .content
        dateField.isHidden = style != .content
        separator.isHidden = style != .content
    }

    func setEditing(_ editing: Bool) {
        titleField.isEditable = editing
        titleField.isSelectable = editing
        titleField.drawsBackground = editing
        titleField.backgroundColor = editing ? .textBackgroundColor : .clear
        titleField.isBordered = editing
        if !editing { updateDecorations() }
    }

    override func layout() {
        super.layout()
        // Row and tile layouts keep a column for the check box so icons don't jump.
        let boxColumn: CGFloat = display.checkBoxes && style != .grid ? 20 : 0
        defer {
            checkBox.frame = style == .grid
                ? NSRect(x: 2, y: bounds.height - 20, width: 18, height: 18)
                : NSRect(x: 2, y: (bounds.height - 18) / 2, width: 18, height: 18)
            let badge = min(32, imageView.frame.width * 0.38)
            badgeView.frame = NSRect(x: imageView.frame.maxX - badge, y: imageView.frame.minY, width: badge, height: badge)
            toolTipSource.install(on: self)
        }
        let b = bounds
        switch style {
        case .grid:
            let icon = min(iconSize, b.width - 8)
            imageView.frame = NSRect(x: (b.width - icon) / 2, y: b.height - icon - 6, width: icon, height: icon)
            titleField.frame = NSRect(x: 4, y: 2, width: b.width - 8, height: max(0, b.height - icon - 12))
        case .row:
            imageView.frame = NSRect(x: 4 + boxColumn, y: (b.height - iconSize) / 2, width: iconSize, height: iconSize)
            titleField.frame = NSRect(x: iconSize + 10 + boxColumn, y: (b.height - 17) / 2, width: b.width - iconSize - 14 - boxColumn, height: 17)
        case .tile:
            imageView.frame = NSRect(x: 6 + boxColumn, y: (b.height - iconSize) / 2, width: iconSize, height: iconSize)
            let x = iconSize + 14 + boxColumn
            let width = b.width - x - 6
            titleField.frame = NSRect(x: x, y: b.height / 2 + 6, width: width, height: 17)
            detailField.frame = NSRect(x: x, y: b.height / 2 - 10, width: width, height: 15)
            secondDetailField.frame = NSRect(x: x, y: b.height / 2 - 25, width: width, height: 15)
        case .content:
            // Icon, then name over type on the left; date and size in a column on the right.
            imageView.frame = NSRect(x: 8 + boxColumn, y: (b.height - iconSize) / 2, width: iconSize, height: iconSize)
            let x = iconSize + 18 + boxColumn
            let right: CGFloat = min(240, b.width * 0.4)
            let width = b.width - x - right - 12
            titleField.frame = NSRect(x: x, y: b.height / 2 + 2, width: width, height: 17)
            detailField.frame = NSRect(x: x, y: b.height / 2 - 16, width: width, height: 15)
            dateField.frame = NSRect(x: b.width - right, y: b.height / 2 + 2, width: right - 8, height: 15)
            secondDetailField.frame = NSRect(x: b.width - right, y: b.height / 2 - 16, width: right - 8, height: 15)
            separator.frame = NSRect(x: 4, y: 0, width: b.width - 8, height: 1)
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

/// A collapsible group header in the icon layouts: chevron + "Today (3)" followed by a hairline.
final class GridGroupHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("GridGroupHeader")
    var onToggle: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private let chevron = NSImageView()
    private let label = NSTextField.label("", size: 12.5, weight: .semibold, color: .controlAccentColor)
    private let line = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.contentTintColor = .controlAccentColor
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)
        addSubview(label)
        addSubview(line)
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            chevron.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            line.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            line.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(title: String, count: Int, collapsed: Bool) {
        chevron.image = NSImage.symbol(collapsed ? "chevron.right" : "chevron.down", size: 10, weight: .semibold)
        label.stringValue = "\(title) (\(count))"
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }
}
