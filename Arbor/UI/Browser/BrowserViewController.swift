import AppKit
import Quartz

/// One Explorer tab: address bar, command bar, navigation pane, folder view, preview pane, status bar.
///
/// It owns the tab's state (location, history, items, view settings) and is the single place
/// where commands from menus, the command bar, context menus and the keyboard are carried out.
final class BrowserViewController: NSViewController {
    // MARK: State
    var history: NavigationHistory
    var location: Location { history.current }
    private(set) var rawItems: [FileItem] = []
    private(set) var items: [FileItem] = []
    var viewSettings: FolderViewSettings
    private var loadGeneration = 0
    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private(set) var isBusy = false { didSet { statusBar.setBusy(isBusy) } }
    private var pendingSelection: Set<URL> = []
    private var pendingSelectionDeadline = Date.distantPast
    var pendingRename: URL?
    var renameBatch: [FileItem] = []
    var lastTypeSelect = Date.distantPast
    var quickLookURLs: [URL] = []
    var sharePicker: NSSharingServicePicker?

    // MARK: Views
    let addressBar = AddressBarView()
    let commandBar = CommandBarView()
    let statusBar = StatusBarView()
    let navigationPane = NavigationPaneController()
    let contentHost = ContentHostViewController()
    let previewPane = PreviewPaneController()
    private let splitController = NSSplitViewController()
    private(set) var navigationSplitItem: NSSplitViewItem!
    private(set) var previewSplitItem: NSSplitViewItem!
    lazy var detailsController: DetailsViewController = {
        let controller = DetailsViewController()
        controller.delegate = self
        return controller
    }()
    lazy var iconsController: IconGridViewController = {
        let controller = IconGridViewController()
        controller.delegate = self
        return controller
    }()
    lazy var thisMacController: ThisMacViewController = {
        let controller = ThisMacViewController()
        controller.delegate = self
        return controller
    }()
    private(set) var presenter: ItemPresenter?
    private let watcher = DirectoryWatcher()
    private var observers: [NSObjectProtocol] = []
    private var didApplyInitialSplit = false

    init(location: Location, select: [URL] = []) {
        let start = location.normalized
        history = NavigationHistory(start: start)
        viewSettings = FolderViewStore.shared.settings(for: start)
        super.init(nibName: nil, bundle: nil)
        setPendingSelection(Set(select))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        loadTask?.cancel()
        searchTask?.cancel()
    }

    // MARK: Layout

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1180, height: 720))

        addChild(splitController)
        let split = splitController.splitView
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "ArborMainSplit"

        navigationSplitItem = NSSplitViewItem(viewController: navigationPane)
        navigationSplitItem.minimumThickness = 150
        navigationSplitItem.maximumThickness = 520
        navigationSplitItem.canCollapse = true
        navigationSplitItem.holdingPriority = NSLayoutConstraint.Priority(260)
        navigationSplitItem.isCollapsed = !Preferences.shared.showNavigationPane

        let contentItem = NSSplitViewItem(viewController: contentHost)
        contentItem.minimumThickness = 320

        previewSplitItem = NSSplitViewItem(viewController: previewPane)
        previewSplitItem.minimumThickness = 220
        previewSplitItem.canCollapse = true
        previewSplitItem.holdingPriority = NSLayoutConstraint.Priority(259)
        previewSplitItem.isCollapsed = !Preferences.shared.showPreviewPane

        splitController.splitViewItems = [navigationSplitItem, contentItem, previewSplitItem]

        let separator = NSBox()
        separator.boxType = .separator
        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        let splitView = splitController.view
        for subview in [addressBar, commandBar, separator, splitView, topSeparator, statusBar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            addressBar.topAnchor.constraint(equalTo: root.topAnchor),
            addressBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            addressBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            addressBar.heightAnchor.constraint(equalToConstant: 42),

            commandBar.topAnchor.constraint(equalTo: addressBar.bottomAnchor),
            commandBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            commandBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            commandBar.heightAnchor.constraint(equalToConstant: 38),

            separator.topAnchor.constraint(equalTo: commandBar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            splitView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: topSeparator.topAnchor),

            topSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topSeparator.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addressBar.delegate = self
        commandBar.delegate = self
        navigationPane.delegate = self
        statusBar.onViewModeSelected = { [weak self] mode in self?.setViewMode(mode) }
        watcher.onChange = { [weak self] in self?.reload() }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .arborPreferencesChanged, object: nil, queue: .main) { [weak self] _ in
            self?.preferencesChanged()
        })
        observers.append(center.addObserver(forName: .arborFoldersChanged, object: nil, queue: .main) { [weak self] note in
            guard let self, let current = self.location.folderURL else { return }
            let folders = note.userInfo?["folders"] as? [URL] ?? []
            if folders.contains(where: { $0.isSameItem(as: current) }) { self.reload() }
        })
        observers.append(center.addObserver(forName: .arborClipboardChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.presenter?.updateDecorations(self.presentationContext())
            self.updateCommandStates()
        })
        observers.append(center.addObserver(forName: .arborVolumesChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.location.isThisMac { self.thisMacController.reload() }
            if let folder = self.location.scopeURL, !FileManager.default.fileExists(atPath: folder.path) {
                self.history.replaceCurrent(with: .thisMac)
                self.displayLocation()
            }
        })

        displayLocation()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateWindowTitle()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didApplyInitialSplit else { return }
        didApplyInitialSplit = true
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames ArborMainSplit") == nil {
            splitController.splitView.setPosition(230, ofDividerAt: 0)
        }
        presenter?.focusContent()
    }

    // MARK: Navigation

    /// Go somewhere new (adds to Back history). Opening a file path opens the file instead.
    func navigate(to target: Location, select: Set<URL> = []) {
        let destination = target.normalized
        if case .folder(let url) = destination {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                FileOperationService.shared.showAlert(
                    message: "Arbor can't find “\(url.path)”.",
                    info: "Check the spelling and try again.",
                    window: view.window
                )
                return
            }
            if !isDirectory.boolValue {
                NSWorkspace.shared.open(url)
                return
            }
        }
        guard destination != location else {
            if !select.isEmpty { presenter?.select(select, scroll: true) } else { reload() }
            return
        }
        history.visit(destination)
        setPendingSelection(select)
        displayLocation()
    }

    func goBack(steps: Int = 1) {
        let from = location
        guard history.goBack(steps: steps) != nil else { return }
        setPendingSelection(childSelection(from: from, to: location))
        displayLocation()
    }

    func goForward(steps: Int = 1) {
        let from = location
        guard history.goForward(steps: steps) != nil else { return }
        setPendingSelection(childSelection(from: from, to: location))
        displayLocation()
    }

    func goUp() {
        guard let parent = parentLocation(of: location) else { return }
        let from = location
        navigate(to: parent, select: childSelection(from: from, to: parent))
    }

    func parentLocation(of location: Location) -> Location? {
        switch location {
        case .thisMac: return nil
        case .search(let root, _): return .folder(root)
        case .folder(let url): return url.isVolumeRoot ? .thisMac : .folder(url.parentFolder)
        }
    }

    /// Going up or back selects the folder you came from, like Explorer.
    private func childSelection(from: Location, to: Location) -> Set<URL> {
        guard let fromURL = from.scopeURL else { return [] }
        guard let toURL = to.folderURL else {
            return to.isThisMac ? Set(VolumeService.volume(containing: fromURL, in: VolumeService.mountedVolumes()).map { [$0.url] } ?? []) : []
        }
        guard fromURL.isDescendant(of: toURL), let first = fromURL.folderChain(below: toURL).first else { return [] }
        return [first]
    }

    func setPendingSelection(_ urls: Set<URL>) {
        pendingSelection = urls
        pendingSelectionDeadline = Date().addingTimeInterval(3)
    }

    /// Shows the current location: picks the view, starts loading or searching, updates the chrome.
    func displayLocation() {
        loadTask?.cancel()
        searchTask?.cancel()
        loadGeneration += 1
        isBusy = false
        rawItems = []
        items = []
        viewSettings = FolderViewStore.shared.settings(for: location)
        updateChrome()
        navigationPane.reveal(location)

        switch location {
        case .thisMac:
            watcher.watch(nil)
            presenter = nil
            contentHost.show(thisMacController)
            contentHost.setMessage(nil)
            thisMacController.reload()
            if let selected = pendingSelection.first { thisMacController.select(selected) }
            pendingSelection = []
        case .folder(let url):
            watcher.watch(url)
            installPresenter()
            presenter?.show(items: [], context: presentationContext(), scrollToTop: true)
            reload(scrollToTop: true)
        case .search(let root, let query):
            watcher.watch(nil)
            installPresenter()
            startSearch(root: root, query: query)
        }
        selectionDidChange()
    }

    func updateChrome() {
        addressBar.display(
            location: location,
            canGoBack: history.canGoBack,
            canGoForward: history.canGoForward,
            canGoUp: parentLocation(of: location) != nil
        )
        statusBar.viewMode = viewSettings.viewMode
        updateWindowTitle()
    }

    private func updateWindowTitle() {
        view.window?.title = location.title
        view.window?.tab.title = location.title
    }

    /// Swaps between the Details table and the icon grid as the view mode requires.
    func installPresenter() {
        let mode = viewSettings.viewMode
        let target: ItemPresenter = mode == .details ? detailsController : iconsController
        if mode != .details { iconsController.setMode(mode) }
        let previous = presenter
        let window = view.window
        let hadFocus = previous?.containsFirstResponder == true || window?.firstResponder == nil || window?.firstResponder === window
        presenter = target
        contentHost.show(target)
        if previous !== target {
            let selection = Set(previous?.selectedItems.map(\.url) ?? [])
            target.show(items: items, context: presentationContext(), scrollToTop: true)
            if !selection.isEmpty { target.select(selection, scroll: true) }
            // The old view just left the window; hand keyboard focus to the new one.
            if hadFocus || window?.firstResponder == nil || window?.firstResponder === window { target.focusContent() }
        }
    }

    func presentationContext() -> PresentationContext {
        PresentationContext(
            showExtensions: Preferences.shared.showExtensions,
            cutPaths: FileClipboard.shared.cutPaths,
            isSearch: location.isSearch,
            viewMode: viewSettings.viewMode,
            sort: viewSettings.sort
        )
    }

    // MARK: Loading

    func reload(scrollToTop: Bool = false) {
        switch location {
        case .thisMac:
            thisMacController.reload()
        case .search(let root, let query):
            startSearch(root: root, query: query)
        case .folder(let url):
            loadGeneration += 1
            let generation = loadGeneration
            loadTask?.cancel()
            let showHidden = Preferences.shared.showHidden
            let busyTimer = DispatchWorkItem { [weak self] in
                if self?.loadGeneration == generation { self?.isBusy = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: busyTimer)
            loadTask = Task { [weak self] in
                let result: Result<[FileItem], Error>
                do {
                    result = .success(try await DirectoryLoader.load(url, showHidden: showHidden))
                } catch {
                    result = .failure(error)
                }
                busyTimer.cancel()
                guard let self, generation == self.loadGeneration else { return }
                self.isBusy = false
                switch result {
                case .success(let loaded):
                    self.rawItems = loaded
                    self.contentHost.setMessage(nil)
                    self.applyItems(scrollToTop: scrollToTop)
                case .failure(let error):
                    self.handleLoadFailure(url, error: error)
                }
            }
        }
    }

    private func handleLoadFailure(_ url: URL, error: Error) {
        if !FileManager.default.fileExists(atPath: url.path) {
            // The folder disappeared (deleted, renamed, drive ejected): go to the nearest folder that exists.
            var candidate = url.parentFolder
            while !FileManager.default.fileExists(atPath: candidate.path), candidate.pathKey != "/" {
                candidate = candidate.parentFolder
            }
            history.replaceCurrent(with: .folder(candidate))
            displayLocation()
            return
        }
        rawItems = []
        applyItems()
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
            contentHost.setMessage("You don't currently have permission to access this folder.\n\nTo open it, give Arbor access in System Settings › Privacy & Security › Files and Folders (or Full Disk Access).")
        } else {
            contentHost.setMessage(error.localizedDescription)
        }
    }

    private func startSearch(root: URL, query: String) {
        searchTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        rawItems = []
        isBusy = true
        applyItems(scrollToTop: true)
        let stream = SearchService.search(root: root, query: query, showHidden: Preferences.shared.showHidden)
        searchTask = Task { [weak self] in
            for await batch in stream {
                guard let self, generation == self.loadGeneration, !Task.isCancelled else { return }
                self.rawItems += batch
                self.applyItems()
            }
            guard let self, generation == self.loadGeneration, !Task.isCancelled else { return }
            self.isBusy = false
            self.applyItems()
        }
    }

    /// Sorts the loaded items and hands them to the current view.
    func applyItems(scrollToTop: Bool = false) {
        items = rawItems.sorted(by: viewSettings.sort)
        presenter?.show(items: items, context: presentationContext(), scrollToTop: scrollToTop)
        applyPendingSelection()

        switch location {
        case .search:
            contentHost.setMessage(items.isEmpty ? (isBusy ? "Searching…" : "No items match your search.") : nil)
        case .folder:
            if items.isEmpty {
                if contentHost.message == nil { contentHost.setMessage("This folder is empty.") }
            } else {
                contentHost.setMessage(nil)
            }
        case .thisMac:
            break
        }
        selectionDidChange()
    }

    private func applyPendingSelection() {
        if !pendingSelection.isEmpty {
            if Date() > pendingSelectionDeadline {
                pendingSelection = []
            } else {
                let present = Set(items.map(\.url.pathKey))
                let matched = pendingSelection.filter { present.contains($0.pathKey) }
                if !matched.isEmpty {
                    presenter?.select(Set(matched), scroll: true)
                    pendingSelection = []
                }
            }
        }
        if let rename = pendingRename, items.contains(where: { $0.url.isSameItem(as: rename) }) {
            pendingRename = nil
            DispatchQueue.main.async { [weak self] in self?.presenter?.beginRename(rename) }
        }
    }

    /// After a paste, drop or create, select the new items once they appear.
    func selectAfterOperation(_ urls: [URL], in folder: URL, rename: URL? = nil) {
        guard let current = location.folderURL, current.isSameItem(as: folder) else { return }
        setPendingSelection(Set(urls))
        pendingRename = rename
        reload()
    }

    /// Reflects a rename in the list right away, so a quick F2 never edits a stale name.
    func applyLocalRenames(_ pairs: [(from: URL, to: URL)]) {
        var changed = false
        for pair in pairs {
            guard let index = rawItems.firstIndex(where: { $0.url.isSameItem(as: pair.from) }),
                  let renamed = FileItem(url: pair.to) else { continue }
            rawItems[index] = renamed
            changed = true
        }
        guard changed else { return }
        setPendingSelection(Set(pairs.map(\.to)))
        applyItems()
    }

    // MARK: Selection

    var selectedContentItems: [FileItem] {
        if location.isThisMac { return thisMacController.selectedItem.map { [$0] } ?? [] }
        return presenter?.selectedItems ?? []
    }

    func selectionDidChange() {
        let selection = selectedContentItems
        let files = selection.filter { !$0.isFolder }
        let size: Int64? = files.isEmpty ? nil : files.reduce(0) { $0 + ($1.size ?? 0) }
        let count = location.isThisMac ? thisMacController.itemCount : items.count
        statusBar.update(itemCount: count, selectedCount: selection.count, selectedSize: size)
        updateCommandStates()
        if !previewSplitItem.isCollapsed { previewPane.show(selection) }
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible, panel.dataSource === self {
            quickLookURLs = selection.map(\.url)
            panel.reloadData()
        }
    }

    func updateCommandStates() {
        var state = CommandState()
        state.canCreate = location.folderURL != nil
        state.canCut = canPerform(#selector(cut(_:)))
        state.canCopy = canPerform(#selector(copy(_:)))
        state.canPaste = canPerform(#selector(paste(_:)))
        state.canRename = canPerform(#selector(renameSelection(_:)))
        state.canShare = !selectedContentItems.isEmpty
        state.canDelete = canPerform(#selector(moveToTrash(_:)))
        state.previewVisible = !previewSplitItem.isCollapsed
        commandBar.update(state)
    }

    // MARK: View settings

    func setViewMode(_ mode: ViewMode) {
        viewSettings.viewMode = mode
        FolderViewStore.shared.save(viewSettings, for: location)
        statusBar.viewMode = mode
        guard !location.isThisMac else { return }
        installPresenter()
        presenter?.show(items: items, context: presentationContext(), scrollToTop: false)
    }

    func setSort(_ sort: SortOrder) {
        viewSettings.sort = sort
        FolderViewStore.shared.save(viewSettings, for: location)
        applyItems()
    }

    private func preferencesChanged() {
        IconCache.invalidate()
        reload()
    }

    // MARK: Panes

    func setNavigationPaneVisible(_ visible: Bool) {
        navigationSplitItem.animator().isCollapsed = !visible
        Preferences.shared.showNavigationPane = visible
    }

    func setPreviewPaneVisible(_ visible: Bool) {
        previewSplitItem.animator().isCollapsed = !visible
        Preferences.shared.showPreviewPane = visible
        if visible { previewPane.show(selectedContentItems) }
        updateCommandStates()
    }
}
