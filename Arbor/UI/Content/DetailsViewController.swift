import AppKit

/// Explorer's Details view: sortable columns, inline rename, type-to-select, drag and drop.
final class DetailsViewController: NSViewController, ItemPresenter, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    weak var delegate: ItemPresenterDelegate?
    let tableView = ExplorerTableView()
    private var items: [FileItem] = []
    private var context = PresentationContext(showExtensions: false, cutPaths: [], isSearch: false, viewMode: .details, sort: SortOrder())
    private var suppressSortCallback = false
    private var renamingURL: URL?
    private var renameCancelled = false
    /// A reload that arrived mid-rename; applied when editing ends so the edit isn't destroyed.
    private var deferredShow: (items: [FileItem], context: PresentationContext)?

    enum Column: String, CaseIterable {
        case name, folder, dateModified, type, size, dateCreated

        var title: String {
            switch self {
            case .name: return "Name"
            case .folder: return "Folder"
            case .dateModified: return "Date modified"
            case .type: return "Type"
            case .size: return "Size"
            case .dateCreated: return "Date created"
            }
        }

        var width: CGFloat {
            switch self {
            case .name: return 300
            case .folder: return 280
            case .dateModified, .dateCreated: return 150
            case .type: return 160
            case .size: return 90
            }
        }

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
        var sortKey: SortKey? { SortKey(rawValue: rawValue) }
    }

    private static let hiddenColumnsKey = "DetailsHiddenColumns"

    override func loadView() {
        tableView.style = .fullWidth
        tableView.rowHeight = 24
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
            return self.delegate?.presenter(self, menuFor: self.selectedItems)
        }
        tableView.onSlowClick = { [weak self] row in
            guard let self, self.items.indices.contains(row) else { return }
            self.beginRename(self.items[row].url)
        }

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
        tableView.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0] : nil }
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
        items = newItems
        context = newContext
        tableView.tableColumn(withIdentifier: Column.folder.identifier)?.isHidden = !newContext.isSearch
        suppressSortCallback = true
        tableView.sortDescriptors = [NSSortDescriptor(key: newContext.sort.key.rawValue, ascending: newContext.sort.ascending)]
        suppressSortCallback = false
        tableView.reloadData()
        let rows = IndexSet(items.indices.filter { previouslySelected.contains(items[$0].url.pathKey) })
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        if scrollToTop { tableView.scrollRowToVisible(0) }
    }

    func updateDecorations(_ newContext: PresentationContext) {
        context = newContext
        guard !items.isEmpty, renamingURL == nil else { return }
        tableView.reloadData(forRowIndexes: IndexSet(items.indices), columnIndexes: IndexSet(tableView.tableColumns.indices))
    }

    func select(_ urls: Set<URL>, scroll: Bool) {
        guard renamingURL == nil else { return }  // changing selection would end the edit
        let keys = pathKeys(urls)
        let rows = IndexSet(items.indices.filter { keys.contains(items[$0].url.pathKey) })
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        if scroll, let first = rows.first { tableView.scrollRowToVisible(first) }
        delegate?.presenterSelectionDidChange(self)
    }

    func selectAllItems() { tableView.selectAll(nil) }
    func selectNoItems() { tableView.deselectAll(nil) }

    func invertSelection() {
        let all = IndexSet(items.indices)
        tableView.selectRowIndexes(all.subtracting(tableView.selectedRowIndexes), byExtendingSelection: false)
    }

    func selectEdge(last: Bool) {
        guard !items.isEmpty else { return }
        let row = last ? items.count - 1 : 0
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    func focusContent() {
        view.window?.makeFirstResponder(tableView)
    }

    // MARK: Rename

    func beginRename(_ url: URL) {
        guard let row = items.firstIndex(where: { $0.url.isSameItem(as: url) }),
              let columnIndex = tableView.tableColumns.firstIndex(where: { $0.identifier == Column.name.identifier }) else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        guard let cell = tableView.view(atColumn: columnIndex, row: row, makeIfNecessary: true) as? NameCellView,
              let field = cell.textField else { return }
        renamingURL = items[row].url
        renameCancelled = false
        cell.setEditing(true)
        view.window?.makeFirstResponder(field)
        selectBaseName(in: field, item: items[row], displayed: field.stringValue)
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
        let row = tableView.clickedRow
        guard items.indices.contains(row) else { return }
        delegate?.presenter(self, open: selectedItems.isEmpty ? [items[row]] : selectedItems)
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
        let fit = NSMenuItem(title: "Size All Columns to Fit", action: #selector(sizeColumnsToFit), keyEquivalent: "")
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

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

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
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue), items.indices.contains(row) else { return nil }
        let item = items[row]
        let dimmed = context.isDimmed(item)
        if column == .name {
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NameCellView ?? NameCellView(identifier: tableColumn.identifier)
            cell.textField?.stringValue = text(for: .name, item: item)
            cell.textField?.delegate = self
            cell.imageView?.image = IconCache.icon(for: item.url)
            cell.alphaValue = dimmed ? 0.5 : 1
            cell.toolTip = item.isFolder ? nil : "Type: \(item.kind)\nSize: \(item.size.map(Format.bytes) ?? "—")\nDate modified: \(Format.date(item.modified))"
            return cell
        }
        let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? TextCellView ?? TextCellView(identifier: tableColumn.identifier)
        cell.textField?.stringValue = text(for: column, item: item)
        cell.textField?.alignment = column == .size ? .right : .left
        cell.alphaValue = dimmed ? 0.5 : 1
        return cell
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableColumn?.identifier == Column.name.identifier, items.indices.contains(row) else { return nil }
        return items[row].displayName(showExtensions: context.showExtensions)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        delegate?.presenterSelectionDidChange(self)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !suppressSortCallback, let descriptor = tableView.sortDescriptors.first,
              let raw = descriptor.key, let key = SortKey(rawValue: raw) else { return }
        delegate?.presenter(self, didChangeSort: SortOrder(key: key, ascending: descriptor.ascending))
    }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        items.indices.contains(row) ? items[row].url as NSURL : nil
    }

    private func dropTarget(row: Int, operation: NSTableView.DropOperation) -> FileItem? {
        guard operation == .on, items.indices.contains(row), items[row].isFolder else { return nil }
        return items[row]
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
    var onSlowClick: ((Int) -> Void)?
    private var slowClickRow = -1

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
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
        let column = column(at: point)
        let onName = column >= 0 && tableColumns[column].identifier.rawValue == DetailsViewController.Column.name.rawValue
        let plainClick = event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
        let eligible = event.clickCount == 1 && plainClick && onName && row >= 0
            && selectedRowIndexes == IndexSet(integer: row) && window?.firstResponder === self
        let started = Date()
        super.mouseDown(with: event)
        if eligible, selectedRowIndexes == IndexSet(integer: row), Date().timeIntervalSince(started) < 0.5 {
            slowClickRow = row
            perform(#selector(fireSlowClick), with: nil, afterDelay: NSEvent.doubleClickInterval + 0.05)
        }
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
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
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
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
