import AppKit

protocol NavigationPaneDelegate: AnyObject {
    func navigationPane(_ pane: NavigationPaneController, didSelect location: Location)
    func navigationPane(_ pane: NavigationPaneController, openInNewTab location: Location)
    func navigationPane(_ pane: NavigationPaneController, menuFor node: TreeNode) -> NSMenu?
    func navigationPane(_ pane: NavigationPaneController, dropOperationFor info: NSDraggingInfo, into folder: URL) -> NSDragOperation
    func navigationPane(_ pane: NavigationPaneController, acceptDrop info: NSDraggingInfo, into folder: URL) -> Bool
}

/// One row of the navigation tree. Children load lazily the first time a row is expanded.
final class TreeNode {
    enum Kind { case home, iCloud, pinned, frequent, thisMac, volume, folder, separator }

    let kind: Kind
    let url: URL?
    let title: String
    weak var parent: TreeNode?
    var children: [TreeNode]?
    var isLoading = false
    var pendingCompletions: [() -> Void] = []

    init(kind: Kind, url: URL?, title: String, parent: TreeNode? = nil) {
        self.kind = kind
        self.url = url
        self.title = title
        self.parent = parent
    }

    var isExpandable: Bool {
        guard kind != .separator else { return false }
        return children.map { !$0.isEmpty } ?? true
    }

    var location: Location? {
        switch kind {
        case .separator: return nil
        case .thisMac: return .thisMac
        default: return url.map { .folder($0) }
        }
    }

    var icon: NSImage? {
        switch kind {
        case .thisMac: return NSImage(named: NSImage.computerName)
        case .separator: return nil
        default: return url.map { IconCache.icon(for: $0) }
        }
    }
}

/// Explorer's navigation pane: Home, iCloud Drive, pinned folders, This Mac › drives › folders.
final class NavigationPaneController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var delegate: NavigationPaneDelegate?
    let outlineView = NavigationOutlineView()
    private var roots: [TreeNode] = []
    private var suppressSelectionEvents = false
    private var revealGeneration = 0
    private var observers: [NSObjectProtocol] = []
    private var lastRevealed: Location?
    private var rootsSignature = ""

    /// What the top level depends on; when it changes the roots are rebuilt.
    private var currentRootsSignature: String {
        let prefs = Preferences.shared
        let frequent = prefs[.showFrequentFolders] ? RecentItems.shared.frequentFolders().map(\.pathKey) : []
        return "\(prefs[.showThisMac])|\(prefs[.compactView])|\(frequent.joined(separator: ":"))"
    }

    var hasFocus: Bool { view.window?.firstResponder === outlineView }

    var selectedNode: TreeNode? {
        let row = outlineView.selectedRow
        return row >= 0 ? outlineView.item(atRow: row) as? TreeNode : nil
    }

    var selectedURL: URL? { selectedNode?.url }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .inset
        outlineView.selectionHighlightStyle = .regular
        outlineView.backgroundColor = .clear
        outlineView.rowSizeStyle = .custom
        outlineView.indentationPerLevel = 12
        outlineView.autoresizesOutlineColumn = false
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        column.minWidth = 120
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask([.copy, .move, .generic, .link], forLocal: false)
        outlineView.setDraggingSourceOperationMask([.copy, .move, .generic, .link], forLocal: true)
        outlineView.menuProvider = { [weak self] node in
            guard let self, let node else { return nil }
            return self.delegate?.navigationPane(self, menuFor: node)
        }
        outlineView.onMiddleClick = { [weak self] node in
            guard let self, let location = node?.location else { return }
            self.delegate?.navigationPane(self, openInNewTab: location)
        }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 230, height: 500))
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildRoots()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .arborPinsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.buildRoots()
        })
        observers.append(center.addObserver(forName: .arborFoldersChanged, object: nil, queue: .main) { [weak self] note in
            let folders = note.userInfo?["folders"] as? [URL] ?? []
            self?.refresh(folders: folders)
        })
        observers.append(center.addObserver(forName: .arborPreferencesChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.currentRootsSignature != self.rootsSignature { self.buildRoots() } else { self.refreshAllLoaded() }
        })
        observers.append(center.addObserver(forName: .arborRecentsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.currentRootsSignature != self.rootsSignature else { return }
            self.buildRoots()
        })
        observers.append(center.addObserver(forName: .arborVolumesChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self, let thisMac = self.roots.first(where: { $0.kind == .thisMac }) else { return }
            self.reloadChildren(of: thisMac)
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Keep the single column as wide as the pane so names use all the space.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard let scroll = view as? NSScrollView, let column = outlineView.tableColumns.first else { return }
        let width = scroll.contentSize.width
        if abs(column.width - width) > 0.5 { column.width = max(column.minWidth, width) }
    }

    // MARK: Building

    private func buildRoots() {
        let fm = FileManager.default
        var nodes: [TreeNode] = []
        let home = fm.realHomeDirectory.normalizedFolder
        nodes.append(TreeNode(kind: .home, url: home, title: String(localized: "Home")))
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fm.fileExists(atPath: iCloud.path) {
            nodes.append(TreeNode(kind: .iCloud, url: iCloud.normalizedFolder, title: String(localized: "iCloud Drive")))
        }
        nodes.append(TreeNode(kind: .separator, url: nil, title: ""))
        for pin in Preferences.shared.pinnedFolders where fm.fileExists(atPath: pin.path) {
            nodes.append(TreeNode(kind: .pinned, url: pin, title: Location.displayName(of: pin)))
        }
        // "Show frequently used folders": unpinned folders you visit often, under the pins.
        if Preferences.shared[.showFrequentFolders] {
            for folder in RecentItems.shared.frequentFolders() {
                nodes.append(TreeNode(kind: .frequent, url: folder.normalizedFolder, title: Location.displayName(of: folder)))
            }
        }
        var thisMac: TreeNode?
        if Preferences.shared[.showThisMac] {
            nodes.append(TreeNode(kind: .separator, url: nil, title: ""))
            let node = TreeNode(kind: .thisMac, url: nil, title: String(localized: "This Mac"))
            nodes.append(node)
            thisMac = node
        }
        roots = nodes
        rootsSignature = currentRootsSignature
        outlineView.reloadData()
        if let thisMac { outlineView.expandItem(thisMac) }
        if let lastRevealed { reveal(lastRevealed) }
    }

    // MARK: Loading

    private func ensureChildren(of node: TreeNode, completion: @escaping () -> Void) {
        if node.children != nil, !node.isLoading { return completion() }
        node.pendingCompletions.append(completion)
        guard !node.isLoading else { return }
        node.isLoading = true
        loadChildren(of: node) { [weak self] children in
            guard let self else { return }
            node.children = self.merge(existing: node.children, with: children, parent: node)
            node.isLoading = false
            self.outlineView.reloadItem(node, reloadChildren: true)
            let completions = node.pendingCompletions
            node.pendingCompletions = []
            completions.forEach { $0() }
        }
    }

    private func loadChildren(of node: TreeNode, completion: @escaping ([TreeNode]) -> Void) {
        switch node.kind {
        case .separator:
            completion([])
        case .thisMac:
            let volumes = VolumeService.visibleVolumes().map { TreeNode(kind: .volume, url: $0.url, title: $0.name, parent: node) }
            DispatchQueue.main.async { completion(volumes) }
        default:
            guard let url = node.url else { return completion([]) }
            let showHidden = Preferences.shared.showHidden
            Task { @MainActor in
                let folders = await DirectoryLoader.subfolders(of: url, showHidden: showHidden)
                completion(folders.map { TreeNode(kind: .folder, url: $0.folderURL ?? $0.url, title: $0.name, parent: node) })
            }
        }
    }

    /// Keeps existing node objects so expansion state survives a refresh.
    private func merge(existing: [TreeNode]?, with fresh: [TreeNode], parent: TreeNode) -> [TreeNode] {
        guard let existing else { return fresh }
        var byPath: [String: TreeNode] = [:]
        for node in existing { if let key = node.url?.pathKey { byPath[key] = node } }
        return fresh.map { node in
            if let key = node.url?.pathKey, let old = byPath[key], old.title == node.title { return old }
            return node
        }
    }

    private func reloadChildren(of node: TreeNode) {
        guard node.children != nil, !node.isLoading else { return }
        node.isLoading = true
        loadChildren(of: node) { [weak self] children in
            guard let self else { return }
            node.children = self.merge(existing: node.children, with: children, parent: node)
            node.isLoading = false
            self.outlineView.reloadItem(node, reloadChildren: true)
        }
    }

    private func allLoadedNodes() -> [TreeNode] {
        var result: [TreeNode] = []
        func walk(_ nodes: [TreeNode]) {
            for node in nodes {
                result.append(node)
                if let children = node.children { walk(children) }
            }
        }
        walk(roots)
        return result
    }

    func refresh(folders: [URL]) {
        let keys = Set(folders.map(\.pathKey))
        for node in allLoadedNodes() where node.children != nil {
            if let key = node.url?.pathKey, keys.contains(key) { reloadChildren(of: node) }
        }
    }

    func refreshAllLoaded() {
        for node in allLoadedNodes() where node.children != nil { reloadChildren(of: node) }
    }

    // MARK: Reveal the current folder

    func reveal(_ location: Location) {
        lastRevealed = location
        revealGeneration += 1
        let generation = revealGeneration
        guard let target = location.scopeURL else {
            if let thisMac = roots.first(where: { $0.kind == .thisMac }) { select(thisMac) } else { selectNothing() }
            return
        }
        if let direct = roots.first(where: { $0.url?.isSameItem(as: target) == true }) {
            select(direct)
            return
        }
        guard Preferences.shared.expandToOpenFolder else {
            selectNothing()
            return
        }
        #if DEBUG
        if DemoRedactor.enabled {
            selectNothing()
            return
        }
        #endif
        // Prefer showing the folder under Home or iCloud Drive; otherwise under This Mac › drive.
        if let anchor = roots.first(where: { ($0.kind == .home || $0.kind == .iCloud) && $0.url.map(target.isDescendant(of:)) == true }), let anchorURL = anchor.url {
            expand(anchor, chain: ArraySlice(target.folderChain(below: anchorURL)), generation: generation)
        } else if roots.first(where: { $0.kind == .thisMac }) == nil {
            selectNothing()
        } else if let thisMac = roots.first(where: { $0.kind == .thisMac }) {
            ensureChildren(of: thisMac) { [weak self] in
                guard let self, generation == self.revealGeneration else { return }
                self.outlineView.expandItem(thisMac)
                let volumes = thisMac.children ?? []
                guard let volume = volumes
                    .filter({ $0.url.map { target.isSameItem(as: $0) || target.isDescendant(of: $0) } == true })
                    .max(by: { ($0.url?.pathKey.count ?? 0) < ($1.url?.pathKey.count ?? 0) }),
                    let volumeURL = volume.url else {
                    self.select(thisMac)
                    return
                }
                self.expand(volume, chain: ArraySlice(target.folderChain(below: volumeURL)), generation: generation)
            }
        }
    }

    private func expand(_ node: TreeNode, chain: ArraySlice<URL>, generation: Int) {
        guard generation == revealGeneration else { return }
        guard let next = chain.first else { return select(node) }
        ensureChildren(of: node) { [weak self] in
            guard let self, generation == self.revealGeneration else { return }
            self.outlineView.expandItem(node)
            if let child = node.children?.first(where: { $0.url?.isSameItem(as: next) == true }) {
                self.expand(child, chain: chain.dropFirst(), generation: generation)
            } else {
                self.select(node)  // e.g. a hidden folder that isn't in the tree
            }
        }
    }

    private func select(_ node: TreeNode) {
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        suppressSelectionEvents = true
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        suppressSelectionEvents = false
    }

    private func selectNothing() {
        suppressSelectionEvents = true
        outlineView.deselectAll(nil)
        suppressSelectionEvents = false
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? TreeNode else { return roots.count }
        if let children = node.children { return children.count }
        DispatchQueue.main.async { [weak self] in self?.ensureChildren(of: node) {} }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? TreeNode else { return roots[index] }
        return node.children?[index] ?? roots[0]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? TreeNode)?.isExpandable ?? false
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TreeNode else { return nil }
        if node.kind == .separator {
            let line = NSBox()
            line.boxType = .separator
            return line
        }
        let identifier = NSUserInterfaceItemIdentifier("TreeCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? TreeCellView ?? TreeCellView(identifier: identifier)
        cell.configure(title: node.title, icon: node.icon, pinned: node.kind == .pinned)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? TreeNode)?.kind == .separator ? 9 : (Preferences.shared[.compactView] ? 20 : 24)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        NavigationRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? TreeNode)?.kind != .separator
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionEvents, let node = selectedNode, let location = node.location else { return }
        lastRevealed = location
        delegate?.navigationPane(self, didSelect: location)
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? TreeNode, [.folder, .pinned, .frequent].contains(node.kind), let url = node.url else { return nil }
        return url as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let node = item as? TreeNode, let url = node.url, node.kind != .separator else { return [] }
        outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return delegate?.navigationPane(self, dropOperationFor: info, into: url) ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let node = item as? TreeNode, let url = node.url else { return false }
        return delegate?.navigationPane(self, acceptDrop: info, into: url) ?? false
    }
}

final class NavigationOutlineView: NSOutlineView {
    var menuProvider: ((TreeNode?) -> NSMenu?)?
    var onMiddleClick: ((TreeNode?) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        return menuProvider?(row >= 0 ? item(atRow: row) as? TreeNode : nil)
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            let row = row(at: convert(event.locationInWindow, from: nil))
            onMiddleClick?(row >= 0 ? item(atRow: row) as? TreeNode : nil)
            return
        }
        super.otherMouseUp(with: event)
    }
}

final class TreeCellView: NSTableCellView {
    private let pinView = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField.label("", size: 13)
        pinView.image = NSImage.symbol("pin.fill", size: 9)
        pinView.contentTintColor = .tertiaryLabelColor
        pinView.translatesAutoresizingMaskIntoConstraints = false
        [icon, label, pinView].forEach(addSubview)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinView.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            pinView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            pinView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, icon: NSImage?, pinned: Bool) {
        textField?.stringValue = title
        imageView?.image = icon
        pinView.isHidden = !pinned
    }
}

/// Draws a clean rounded selection pill in the navigation pane (never clips or turns black).
private final class NavigationRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 8, dy: 1)
        let color = isEmphasized
            ? NSColor.controlAccentColor.withAlphaComponent(0.18)
            : NSColor.labelColor.withAlphaComponent(0.09)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }
}
