import AppKit

/// Explorer's Details view: sortable columns, inline rename, type-to-select, drag and drop.
final class DetailsViewController: NSViewController, ItemPresenter, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    weak var delegate: ItemPresenterDelegate?
    let tableView = ExplorerTableView()
    /// All items, in display order (flattened across groups).
    private var items: [FileItem] = []
    /// Collapsed group titles for the current folder/grouping.
    private var collapsedGroups: Set<String> = []
    /// What each table row shows: an item, or a group header ("Today (3)").
    private var rows: [Row] = []
    private enum Row {
        case header(String, count: Int, collapsed: Bool)
        case item(FileItem)
    }

    private func item(_ row: Int) -> FileItem? {
        guard rows.indices.contains(row), case .item(let item) = rows[row] else { return nil }
        return item
    }

    private func headerTitle(_ row: Int) -> String? {
        guard rows.indices.contains(row), case .header(let title, _, _) = rows[row] else { return nil }
        return title
    }

    private var itemRows: [Int] { rows.indices.filter { item($0) != nil } }

    private func row(of url: URL) -> Int? {
        rows.indices.first { item($0)?.url.isSameItem(as: url) == true }
    }

    private static func buildRows(_ items: [FileItem], groupBy: GroupKey, collapsed: Set<String>) -> [Row] {
        guard groupBy != .none else { return items.map(Row.item) }
        return FileGrouping.groups(items, by: groupBy).flatMap { group in
            let isCollapsed = collapsed.contains(group.title)
            let header = Row.header(group.title, count: group.items.count, collapsed: isCollapsed)
            return isCollapsed ? [header] : [header] + group.items.map(Row.item)
        }
    }
    private var context = PresentationContext(showExtensions: false, cutPaths: [], isSearch: false, viewMode: .details, sort: SortOrder())
    private var suppressSortCallback = false
    private var renamingURL: URL?
    private var renameCancelled = false
    /// A reload that arrived mid-rename; applied when editing ends so the edit isn't destroyed.
    private var deferredShow: (items: [FileItem], context: PresentationContext)?
    private var hoveredRow = -1
    private let pointToSelect = PointToSelect()
    private var nameColumnIndex: Int? { tableView.tableColumns.firstIndex { $0.identifier == Column.name.identifier } }

    enum Column: String, CaseIterable {
        case name, folder, dateModified, type, size, dateCreated

        var title: String {
            switch self {
            case .name: return String(localized: "Name")
            case .folder: return String(localized: "Folder")
            case .dateModified: return String(localized: "Date modified")
            case .type: return String(localized: "Type")
            case .size: return String(localized: "Size")
            case .dateCreated: return String(localized: "Date created")
            }
        }

        var width: CGFloat {
            switch self {
            case .name: return 240
            case .folder: return 260
            case .dateModified, .dateCreated: return 145
            case .type: return 140
            case .size: return 85
            }
        }

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
        var sortKey: SortKey? { SortKey(rawValue: rawValue) }
    }

    private static let hiddenColumnsKey = "DetailsHiddenColumns"

    override func loadView() {
        tableView.style = .fullWidth
        tableView.rowHeight = 26
        tableView.intercellSpacing = NSSize(width: 8, height: 0)
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsTypeSelect = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column == .name ? 120 : 50
            if let key = column.sortKey {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
            }
            if column == .size { tableColumn.headerCell.alignment = .right }
            tableView.addTableColumn(tableColumn)
        }

        let hidden = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenColumnsKey) ?? [Column.dateCreated.rawValue])
        for column in tableView.tableColumns {
            column.isHidden = hidden.contains(column.identifier.rawValue) || column.identifier == Column.folder.identifier
        }
        tableView.autosaveName = "ArborDetailsColumns"
        tableView.autosaveTableColumns = true

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic, .link], forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic, .link], forLocal: true)
        tableView.draggingDestinationFeedbackStyle = .regular
        tableView.headerView?.menu = makeHeaderMenu()
        tableView.menuProvider = { [weak self] row in
            guard let self else { return nil }
            if let title = self.headerTitle(row) {
                return self.groupHeaderMenu(for: title)
            }
            return self.delegate?.presenter(self, menuFor: self.selectedItems)
        }
        tableView.onGroupClick = { [weak self] row in
            guard let self, let title = self.headerTitle(row) else { return }
            self.toggleGroup(title)
        }
        tableView.onMiddleClick = { [weak self] row in
            guard let self, let item = self.item(row), item.isFolder else { return }
            self.delegate?.presenter(self, openInNewTab: [item])
        }
        tableView.onSlowClick = { [weak self] row in
            guard let self, let item = self.item(row) else { return }
            self.beginRename(item.url)
        }
        tableView.isSingleClickMode = { [weak self] in self?.context.display.singleClickToOpen ?? false }
        tableView.onSingleClickOpen = { [weak self] row in
            guard let self, let item = self.item(row) else { return }
            self.delegate?.presenter(self, open: [item])
        }
        tableView.onHover = { [weak self] row in self?.hoverChanged(row) }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        view = scroll
    }

    // MARK: ItemPresenter

    var keyView: NSView { tableView }

    var selectedItems: [FileItem] {
        tableView.selectedRowIndexes.compactMap { item($0) }
    }

    var containsFirstResponder: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder === tableView || responder.isDescendant(of: tableView)
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
        items = newItems
        rows = Self.buildRows(newItems, groupBy: newContext.groupBy, collapsed: collapsedGroups)
        context = newContext
        tableView.tableColumn(withIdentifier: Column.folder.identifier)?.isHidden = !newContext.isSearch
        applyRowHeight()
        suppressSortCallback = true
        tableView.sortDescriptors = [NSSortDescriptor(key: newContext.sort.key.rawValue, ascending: newContext.sort.ascending)]
        suppressSortCallback = false
        tableView.reloadData()
        let selectedRows = IndexSet(itemRows.filter { previouslySelected.contains(item($0)!.url.pathKey) })
        tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
        if scrollToTop { tableView.scrollRowToVisible(0) }
    }

    // MARK: Collapsible groups

    private func toggleGroup(_ title: String) {
        if collapsedGroups.contains(title) {
            collapsedGroups.remove(title)
        } else {
            collapsedGroups.insert(title)
        }
        rebuildRowsPreservingSelection()
    }

    private func rebuildRowsPreservingSelection() {
        let previouslySelected = Set(selectedItems.map(\.url.pathKey))
        rows = Self.buildRows(items, groupBy: context.groupBy, collapsed: collapsedGroups)
        tableView.reloadData()
        let selectedRows = IndexSet(itemRows.filter { previouslySelected.contains(item($0)!.url.pathKey) })
        tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
        delegate?.presenterSelectionDidChange(self)
    }

    private func expandGroupsContaining(_ keys: Set<String>) {
        guard context.groupBy != .none, !collapsedGroups.isEmpty else { return }
        let groups = FileGrouping.groups(items, by: context.groupBy)
        var changed = false
        for group in groups where collapsedGroups.contains(group.title) {
            if group.items.contains(where: { keys.contains($0.url.pathKey) }) {
                collapsedGroups.remove(group.title)
                changed = true
            }
        }
        if changed {
            rows = Self.buildRows(items, groupBy: context.groupBy, collapsed: collapsedGroups)
            tableView.reloadData()
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
        let allTitles = Set(FileGrouping.groups(items, by: context.groupBy).map(\.title))
        let collapseAll = NSMenuItem(title: String(localized: "Collapse all groups"), action: #selector(collapseAllGroups), keyEquivalent: "")
        collapseAll.target = self
        collapseAll.isEnabled = collapsedGroups.count < allTitles.count
        menu.addItem(collapseAll)
        return menu
    }

    @objc private func toggleGroupFromMenu(_ sender: NSMenuItem) {
        if let title = sender.representedObject as? String { toggleGroup(title) }
    }

    @objc private func expandAllGroups() {
        collapsedGroups = []
        rebuildRowsPreservingSelection()
    }

    @objc private func collapseAllGroups() {
        collapsedGroups = Set(FileGrouping.groups(items, by: context.groupBy).map(\.title))
        rebuildRowsPreservingSelection()
    }

    private func applyRowHeight() {
        let height: CGFloat = context.display.compact ? 22 : 26
        if tableView.rowHeight != height { tableView.rowHeight = height }
    }

    func updateDecorations(_ newContext: PresentationContext) {
        context = newContext
        guard !rows.isEmpty, renamingURL == nil else { return }
        applyRowHeight()
        tableView.reloadData(forRowIndexes: IndexSet(rows.indices), columnIndexes: IndexSet(tableView.tableColumns.indices))
    }

    func select(_ urls: Set<URL>, scroll: Bool) {
        guard renamingURL == nil else { return }  // changing selection would end the edit
        let keys = pathKeys(urls)
        expandGroupsContaining(keys)
        let matching = IndexSet(itemRows.filter { keys.contains(item($0)!.url.pathKey) })
        tableView.selectRowIndexes(matching, byExtendingSelection: false)
        if scroll, let first = matching.first { tableView.scrollRowToVisible(first) }
        delegate?.presenterSelectionDidChange(self)
    }

    func selectAllItems() { tableView.selectAll(nil) }
    func selectNoItems() { tableView.deselectAll(nil) }

    func invertSelection() {
        let all = IndexSet(itemRows)
        tableView.selectRowIndexes(all.subtracting(tableView.selectedRowIndexes), byExtendingSelection: false)
    }

    func selectEdge(last: Bool) {
        guard let row = last ? itemRows.last : itemRows.first else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    func focusContent() {
        view.window?.makeFirstResponder(tableView)
    }

    // MARK: Rename

    func beginRename(_ url: URL) {
        expandGroupsContaining([url.pathKey])
        guard let row = row(of: url), let target = item(row),
              let columnIndex = tableView.tableColumns.firstIndex(where: { $0.identifier == Column.name.identifier }) else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        guard let cell = tableView.view(atColumn: columnIndex, row: row, makeIfNecessary: true) as? NameCellView,
              let field = cell.textField else { return }
        renamingURL = target.url
        renameCancelled = false
        pointToSelect.cancel()
        field.attributedStringValue = itemTitle(text(for: .name, item: target), underline: false, font: .systemFont(ofSize: 13))
        cell.setEditing(true)
        view.window?.makeFirstResponder(field)
        selectBaseName(in: field, item: target, displayed: field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard renamingURL != nil, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        renameCancelled = true
        view.window?.makeFirstResponder(tableView)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let url = renamingURL else { return }
        renamingURL = nil
        (field.superview as? NameCellView)?.setEditing(false)
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
        // Return focus to the list unless the user clicked into another text field.
        DispatchQueue.main.async { [weak self] in
            guard let self, !(self.view.window?.firstResponder is NSTextView) else { return }
            self.view.window?.makeFirstResponder(self.tableView)
        }
    }

    // MARK: Actions

    @objc private func doubleClicked() {
        guard !context.display.singleClickToOpen else { return }  // the first click already opened it
        let row = tableView.clickedRow
        guard let clicked = item(row) else { return }
        delegate?.presenter(self, open: selectedItems.isEmpty ? [clicked] : selectedItems)
    }

    private func makeHeaderMenu() -> NSMenu {
        let menu = NSMenu()
        for column in Column.allCases where column != .name && column != .folder {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let fit = NSMenuItem(title: String(localized: "Size All Columns to Fit"), action: #selector(sizeColumnsToFit), keyEquivalent: "")
        fit.target = self
        menu.addItem(fit)
        menu.delegate = HeaderMenuStateUpdater.shared
        HeaderMenuStateUpdater.shared.tableView = tableView
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let column = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(raw)) else { return }
        column.isHidden.toggle()
        let hidden = tableView.tableColumns
            .filter { $0.isHidden && $0.identifier != Column.folder.identifier }
            .map(\.identifier.rawValue)
        UserDefaults.standard.set(hidden, forKey: Self.hiddenColumnsKey)
    }

    @objc private func sizeColumnsToFit() {
        for column in tableView.tableColumns where !column.isHidden {
            guard let kind = Column(rawValue: column.identifier.rawValue) else { continue }
            var width = (column.headerCell.cellSize.width) + 16
            for item in items.prefix(500) {
                width = max(width, (text(for: kind, item: item) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width + (kind == .name ? 40 : 16))
            }
            column.width = min(width, 600)
        }
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        rows.indices.contains(row) && item(row) == nil
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { item(row) != nil }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        item(row) == nil ? 32 : tableView.rowHeight
    }

    private func text(for column: Column, item: FileItem) -> String {
        switch column {
        case .name: return item.displayName(showExtensions: context.showExtensions)
        case .folder: return item.url.deletingLastPathComponent().path
        case .dateModified: return Format.date(item.modified)
        case .dateCreated: return Format.date(item.created)
        case .type: return item.kind
        case .size: return Format.kilobytes(item.size)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if rows.indices.contains(row), case .header(let title, let count, let collapsed) = rows[row] {
            let identifier = NSUserInterfaceItemIdentifier("GroupHeader")
            let header = tableView.makeView(withIdentifier: identifier, owner: self) as? GroupHeaderView ?? GroupHeaderView(identifier: identifier)
            header.set(title: title, count: count, collapsed: collapsed)
            return header
        }
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue), let item = item(row) else { return nil }
        let dimmed = context.isDimmed(item)
        if column == .name {
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NameCellView ?? NameCellView(identifier: tableColumn.identifier)
            cell.textField?.delegate = self
            cell.representedURL = item.url
            cell.imageView?.image = IconCache.fastIcon(for: item)
            if IconCache.cachedIcon(for: item.url) == nil {
                let targetURL = item.url
                IconCache.loadIcon(for: targetURL) { [weak cell] image in
                    guard let cell, cell.representedURL?.isSameItem(as: targetURL) == true else { return }
                    cell.imageView?.image = image
                }
            }
            cell.alphaValue = dimmed ? 0.5 : 1
            let display = context.display
            cell.toolTipSource.provider = display.popUpDescriptions ? { display.toolTip(for: item) } : nil
            cell.toolTipSource.install(on: cell)
            cell.onToggle = { [weak self, weak cell] in
                guard let self, let cell else { return }
                let row = self.tableView.row(for: cell)
                guard row >= 0 else { return }
                if self.tableView.isRowSelected(row) {
                    self.tableView.deselectRow(row)
                } else {
                    self.tableView.selectRowIndexes([row], byExtendingSelection: true)
                }
            }
            decorate(cell, row: row)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? TextCellView ?? TextCellView(identifier: tableColumn.identifier)
        cell.textField?.stringValue = text(for: column, item: item)
        cell.textField?.alignment = column == .size ? .right : .left
        cell.alphaValue = dimmed ? 0.5 : 1
        return cell
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableColumn?.identifier == Column.name.identifier, let item = item(row) else { return nil }
        return item.displayName(showExtensions: context.showExtensions)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshVisibleDecorations()
        delegate?.presenterSelectionDidChange(self)
    }

    // MARK: Hover, underline and check boxes

    /// Sets the name's underline and the check box for one row (skipped while that row is being renamed).
    private func decorate(_ cell: NameCellView, row: Int) {
        guard let item = item(row) else { return }
        if let renamingURL, item.url.isSameItem(as: renamingURL) { return }
        let selected = tableView.isRowSelected(row)
        let hovered = row == hoveredRow
        let display = context.display
        cell.textField?.attributedStringValue = itemTitle(text(for: .name, item: item), underline: display.underlines(hovered: hovered), font: .systemFont(ofSize: 13))
        cell.setCheckBox(reserved: display.checkBoxes, visible: display.showsCheckBox(selected: selected, hovered: hovered), checked: selected)
    }

    private func decorate(row: Int) {
        guard row >= 0, let column = nameColumnIndex,
              let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? NameCellView else { return }
        decorate(cell, row: row)
    }

    private func refreshVisibleDecorations() {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.length > 0 else { return }
        for row in range.location..<(range.location + range.length) { decorate(row: row) }
    }

    private func hoverChanged(_ row: Int) {
        guard row != hoveredRow else { return }
        let old = hoveredRow
        hoveredRow = row
        decorate(row: old)
        decorate(row: row)
        guard context.display.singleClickToOpen, row >= 0, renamingURL == nil else { return pointToSelect.cancel() }
        pointToSelect.schedule { [weak self] in
            guard let self, self.hoveredRow == row, self.renamingURL == nil, self.item(row) != nil else { return }
            let extend = NSEvent.modifierFlags.contains(.command)
            if extend || self.tableView.selectedRowIndexes != IndexSet(integer: row) {
                self.tableView.selectRowIndexes([row], byExtendingSelection: extend)
            }
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !suppressSortCallback, let descriptor = tableView.sortDescriptors.first,
              let raw = descriptor.key, let key = SortKey(rawValue: raw) else { return }
        delegate?.presenter(self, didChangeSort: SortOrder(key: key, ascending: descriptor.ascending))
    }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        item(row).map { $0.url as NSURL }
    }

    private func dropTarget(row: Int, operation: NSTableView.DropOperation) -> FileItem? {
        guard operation == .on, let target = item(row), target.isFolder else { return nil }
        return target
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let target = dropTarget(row: row, operation: dropOperation)
        if target == nil { tableView.setDropRow(-1, dropOperation: .on) }
        return delegate?.presenter(self, dropOperationFor: info, onto: target) ?? []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        delegate?.presenter(self, acceptDrop: info, onto: dropTarget(row: row, operation: dropOperation)) ?? false
    }
}

/// Keeps the checkmarks in the column-header menu in sync with the visible columns.
final class HeaderMenuStateUpdater: NSObject, NSMenuDelegate {
    static let shared = HeaderMenuStateUpdater()
    weak var tableView: NSTableView?

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            guard let raw = item.representedObject as? String,
                  let column = tableView?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(raw)) else { continue }
            item.state = column.isHidden ? .off : .on
        }
    }
}

/// NSTableView with Explorer mouse behaviour: right-click selects, and a slow second click renames.
final class ExplorerTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?
    var onGroupClick: ((Int) -> Void)?
    var onMiddleClick: ((Int) -> Void)?
    var onSlowClick: ((Int) -> Void)?
    var onSingleClickOpen: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?
    var isSingleClickMode: () -> Bool = { false }
    private var slowClickRow = -1
    private var hoveredRow = -1
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let next = row(at: convert(event.locationInWindow, from: nil))
        if next != hoveredRow {
            let previous = hoveredRow
            hoveredRow = next
            if previous >= 0 { setNeedsDisplay(rect(ofRow: previous)) }
            if next >= 0 { setNeedsDisplay(rect(ofRow: next)) }
        }
        onHover?(next)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if hoveredRow >= 0 {
            let previous = hoveredRow
            hoveredRow = -1
            setNeedsDisplay(rect(ofRow: previous))
        }
        onHover?(-1)
    }

    override func drawRow(_ row: Int, clipRect: NSRect) {
        if row == hoveredRow, !isRowSelected(row) {
            NSColor.labelColor.withAlphaComponent(0.045).setFill()
            NSBezierPath(roundedRect: rect(ofRow: row).insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.drawRow(row, clipRect: clipRect)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, delegate?.tableView?(self, isGroupRow: row) == true {
            return menuProvider?(row)
        }
        if row >= 0 {
            if !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        } else {
            deselectAll(nil)
        }
        window?.makeFirstResponder(self)
        return menuProvider?(row)
    }

    override func mouseDown(with event: NSEvent) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(fireSlowClick), object: nil)
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        if row >= 0, delegate?.tableView?(self, isGroupRow: row) == true {
            onGroupClick?(row)
            return
        }
        let column = column(at: point)
        let onName = column >= 0 && tableColumns[column].identifier.rawValue == DetailsViewController.Column.name.rawValue
        let plainClick = event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
        let singleClickMode = isSingleClickMode()
        let startLocation = NSEvent.mouseLocation
        let eligible = !singleClickMode && event.clickCount == 1 && plainClick && onName && row >= 0
            && selectedRowIndexes == IndexSet(integer: row) && window?.firstResponder === self
        let started = Date()
        super.mouseDown(with: event)
        if singleClickMode, plainClick, event.clickCount == 1, row >= 0 {
            // Open on click, but not when the click turned into a drag.
            let end = NSEvent.mouseLocation
            if hypot(end.x - startLocation.x, end.y - startLocation.y) < 4 { onSingleClickOpen?(row) }
            return
        }
        if eligible, selectedRowIndexes == IndexSet(integer: row), Date().timeIntervalSince(started) < 0.5 {
            slowClickRow = row
            perform(#selector(fireSlowClick), with: nil, afterDelay: NSEvent.doubleClickInterval + 0.05)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            let row = row(at: convert(event.locationInWindow, from: nil))
            if row >= 0 { onMiddleClick?(row) }
            return
        }
        super.otherMouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(fireSlowClick), object: nil)
        super.keyDown(with: event)
    }

    @objc private func fireSlowClick() {
        guard selectedRowIndexes == IndexSet(integer: slowClickRow) else { return }
        onSlowClick?(slowClickRow)
    }
}

final class NameCellView: NSTableCellView {
    let toolTipSource = LazyToolTip()
    let checkBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    var representedURL: URL?
    var onToggle: (() -> Void)?
    private var iconAtLeading: NSLayoutConstraint!
    private var iconAfterCheckBox: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        checkBox.translatesAutoresizingMaskIntoConstraints = false
        checkBox.target = self
        checkBox.action = #selector(toggled)
        checkBox.isHidden = true
        addSubview(checkBox)
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.cell?.isScrollable = true
        addSubview(icon)
        addSubview(field)
        imageView = icon
        textField = field
        iconAtLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        iconAfterCheckBox = icon.leadingAnchor.constraint(equalTo: checkBox.trailingAnchor, constant: 4)
        NSLayoutConstraint.activate([
            iconAtLeading,
            checkBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            checkBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkBox.widthAnchor.constraint(equalToConstant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `reserved` keeps room for the box on every row so icons don't jump; `visible` shows it.
    func setCheckBox(reserved: Bool, visible: Bool, checked: Bool) {
        if iconAfterCheckBox.isActive != reserved {
            iconAtLeading.isActive = !reserved
            iconAfterCheckBox.isActive = reserved
        }
        checkBox.isHidden = !(reserved && visible)
        checkBox.state = checked ? .on : .off
    }

    @objc private func toggled() { onToggle?() }

    override func layout() {
        super.layout()
        toolTipSource.install(on: self)
    }

    func setEditing(_ editing: Bool) {
        guard let field = textField else { return }
        field.isEditable = editing
        field.isSelectable = editing
        field.drawsBackground = editing
        field.backgroundColor = editing ? .textBackgroundColor : .clear
        field.isBordered = editing
        field.lineBreakMode = editing ? .byClipping : .byTruncatingTail
    }
}

final class TextCellView: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField.label("", size: 12.5, color: .secondaryLabelColor)
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Explorer's collapsible group header: chevron + "Today (3)" followed by a hairline.
final class GroupHeaderView: NSTableCellView {
    private let chevron = NSImageView()
    private let label = NSTextField.label("", size: 12.5, weight: .semibold, color: .controlAccentColor)
    private let line = NSBox()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.contentTintColor = .controlAccentColor
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)
        addSubview(label)
        addSubview(line)
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            chevron.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            line.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            line.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(title: String, count: Int, collapsed: Bool) {
        chevron.image = NSImage.symbol(collapsed ? "chevron.right" : "chevron.down", size: 10, weight: .semibold)
        label.stringValue = "\(title) (\(count))"
    }
}
