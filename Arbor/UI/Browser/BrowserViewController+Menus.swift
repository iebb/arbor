import AppKit

/// Context menus and the command bar's drop-down menus.
extension BrowserViewController {
    private func menuItem(_ title: String, _ action: Selector, symbol: String? = nil, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], urls: [URL]? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        if let urls { item.representedObject = urls }
        if let symbol { item.image = NSImage.symbol(symbol) }
        return item
    }

    // MARK: Item context menu

    func itemMenu(for items: [FileItem]) -> NSMenu {
        guard !items.isEmpty else { return backgroundMenu() }
        let urls = items.map(\.url)
        let menu = NSMenu()
        let single = items.count == 1 ? items[0] : nil
        let allFolders = items.allSatisfy(\.isFolder)
        let allFiles = items.allSatisfy { !$0.isFolder }

        let open = menuItem(String(localized: "Open"), #selector(openSelection(_:)), urls: urls)
        open.attributedTitle = NSAttributedString(string: open.title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        menu.addItem(open)
        if allFolders {
            menu.addItem(menuItem(String(localized: "Open in new tab"), #selector(openInNewTab(_:)), symbol: "plus.square.on.square", urls: urls))
            menu.addItem(menuItem(String(localized: "Open in new window"), #selector(openInNewWindow(_:)), symbol: "macwindow.badge.plus", urls: urls))
        }
        if allFiles { menu.addItem(openWithItem(for: urls)) }
        if let single, single.isZipArchive {
            menu.addItem(menuItem(String(localized: "Extract All…"), #selector(extractAll(_:)), symbol: "archivebox", urls: urls))
        }
        menu.addItem(.separator())

        menu.addItem(menuItem(String(localized: "Cut"), #selector(cut(_:)), symbol: "scissors", key: "x", urls: urls))
        menu.addItem(menuItem(String(localized: "Copy"), #selector(copy(_:)), symbol: "doc.on.doc", key: "c", urls: urls))
        if let single, single.isFolder {
            menu.addItem(menuItem(String(localized: "Paste"), #selector(paste(_:)), symbol: "doc.on.clipboard", key: "v", urls: urls))
        }
        menu.addItem(menuItem(String(localized: "Copy as path"), #selector(copyAsPath(_:)), symbol: "link", key: "c", modifiers: [.command, .option], urls: urls))
        menu.addItem(.separator())

        let picker = NSSharingServicePicker(items: urls)
        sharePicker = picker
        menu.addItem(picker.standardShareMenuItem)
        menu.addItem(menuItem(String(localized: "Compress to ZIP file"), #selector(compressToZip(_:)), symbol: "doc.zipper", urls: urls))
        if allFolders {
            menu.addItem(menuItem(String(localized: "Pin to Quick access"), #selector(togglePin(_:)), symbol: "pin", urls: urls))
        }
        if let single, single.isFolder {
            menu.addItem(menuItem(String(localized: "Open in Terminal"), #selector(openInTerminal(_:)), symbol: "terminal", urls: urls))
        }
        menu.addItem(menuItem(String(localized: "Show in Finder"), #selector(showInFinder(_:)), symbol: "macwindow", urls: urls))
        if let single, single.url.isVolumeRoot, single.url.pathKey != "/" {
            menu.addItem(menuItem(String(localized: "Eject"), #selector(ejectVolume(_:)), symbol: "eject", urls: urls))
        }
        menu.addItem(.separator())

        if items.count >= 1, location.folderURL != nil || location.isSearch {
            let rename = menuItem(String(localized: "Rename"), #selector(renameSelection(_:)), symbol: "character.cursor.ibeam", key: functionKey(NSF2FunctionKey), modifiers: [])
            menu.addItem(rename)
        }
        menu.addItem(menuItem(String(localized: "Delete"), #selector(moveToTrash(_:)), symbol: "trash", key: "\u{8}", urls: urls))
        menu.addItem(.separator())
        menu.addItem(menuItem(String(localized: "Properties"), #selector(showProperties(_:)), symbol: "info.circle", key: "i", urls: urls))
        return menu
    }

    private func openWithItem(for urls: [URL]) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Open with"), action: nil, keyEquivalent: "")
        item.image = NSImage.symbol("square.grid.3x3.square")
        let submenu = NSMenu()
        if let first = urls.first {
            let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: first)
            var apps = NSWorkspace.shared.urlsForApplications(toOpen: first)
            if let defaultApp {
                apps.removeAll { $0.isSameItem(as: defaultApp) }
                apps.insert(defaultApp, at: 0)
            }
            for (index, app) in apps.prefix(16).enumerated() {
                var title = FileManager.default.displayName(atPath: app.path)
                if index == 0, defaultApp != nil { title += " (default)" }
                let entry = NSMenuItem(title: title, action: #selector(openWithApplication(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = [app] + urls
                entry.image = NSWorkspace.shared.icon(forFile: app.path).menuSized
                submenu.addItem(entry)
                if index == 0, defaultApp != nil, apps.count > 1 { submenu.addItem(.separator()) }
            }
        }
        submenu.addItem(.separator())
        let other = NSMenuItem(title: String(localized: "Choose another app…"), action: #selector(openWithOtherApplication(_:)), keyEquivalent: "")
        other.target = self
        other.representedObject = urls
        submenu.addItem(other)
        item.submenu = submenu
        return item
    }

    // MARK: Background context menu

    func backgroundMenu() -> NSMenu {
        let menu = NSMenu()
        let viewItem = NSMenuItem(title: String(localized: "View"), action: nil, keyEquivalent: "")
        viewItem.image = NSImage.symbol("square.grid.2x2")
        viewItem.submenu = viewMenu()
        menu.addItem(viewItem)
        let sortItem = NSMenuItem(title: String(localized: "Sort by"), action: nil, keyEquivalent: "")
        sortItem.image = NSImage.symbol("arrow.up.arrow.down")
        sortItem.submenu = sortMenu()
        menu.addItem(sortItem)
        let groupItem = NSMenuItem(title: String(localized: "Group by"), action: nil, keyEquivalent: "")
        groupItem.image = NSImage.symbol("rectangle.3.group")
        groupItem.submenu = groupByMenu()
        menu.addItem(groupItem)
        menu.addItem(menuItem(String(localized: "Refresh"), #selector(refresh(_:)), symbol: "arrow.clockwise", key: functionKey(NSF5FunctionKey), modifiers: []))
        menu.addItem(.separator())

        menu.addItem(menuItem(String(localized: "Paste"), #selector(paste(_:)), symbol: "doc.on.clipboard", key: "v"))
        let undoManager = FileOperationService.shared.undoManager
        if undoManager.canUndo {
            let undo = NSMenuItem(title: undoManager.undoMenuItemTitle, action: Selector(("undo:")), keyEquivalent: "z")
            undo.image = NSImage.symbol("arrow.uturn.backward")
            menu.addItem(undo)
        }
        menu.addItem(.separator())

        let newItem = NSMenuItem(title: String(localized: "New"), action: nil, keyEquivalent: "")
        newItem.image = NSImage.symbol("plus.circle")
        newItem.submenu = newMenu()
        menu.addItem(newItem)
        menu.addItem(.separator())

        if let folder = location.folderURL {
            menu.addItem(menuItem(String(localized: "Open in Terminal"), #selector(openInTerminal(_:)), symbol: "terminal"))
            menu.addItem(menuItem(String(localized: "Show in Finder"), #selector(showInFinder(_:)), symbol: "macwindow", urls: [folder]))
            menu.addItem(.separator())
            menu.addItem(menuItem(String(localized: "Properties"), #selector(showProperties(_:)), symbol: "info.circle", key: "i", urls: [folder]))
        }
        return menu
    }

    // MARK: Drop-down menus (also used by the command bar)

    func newMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem(String(localized: "Folder"), #selector(newFolder(_:)), symbol: "folder.badge.plus", key: "n", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(menuItem(String(localized: "Text Document"), #selector(newTextDocument(_:)), symbol: "doc.text", key: "n", modifiers: [.command, .option]))
        return menu
    }

    func viewMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, mode) in ViewMode.allCases.enumerated() {
            let item = menuItem(mode.title, #selector(setViewModeFromMenu(_:)), symbol: mode.symbolName, key: "\(mode.shortcutNumber)", modifiers: [.control, .shift])
            item.tag = index
            item.state = mode == viewSettings.viewMode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let show = NSMenuItem(title: String(localized: "Show"), action: nil, keyEquivalent: "")
        let showMenu = NSMenu()
        let compact = menuItem(String(localized: "Compact view"), #selector(toggleOption(_:)))
        compact.representedObject = FolderOption.compactView.rawValue
        showMenu.addItem(compact)
        showMenu.addItem(menuItem(String(localized: "Navigation pane"), #selector(toggleNavigationPane(_:))))
        showMenu.addItem(menuItem(String(localized: "Preview pane"), #selector(togglePreviewPane(_:)), key: "p", modifiers: [.option]))
        showMenu.addItem(menuItem(String(localized: "Details pane"), #selector(toggleDetailsPane(_:)), key: "p", modifiers: [.option, .shift]))
        showMenu.addItem(.separator())
        let checkBoxes = menuItem(String(localized: "Item check boxes"), #selector(toggleOption(_:)))
        checkBoxes.representedObject = FolderOption.itemCheckBoxes.rawValue
        showMenu.addItem(checkBoxes)
        showMenu.addItem(menuItem(String(localized: "File name extensions"), #selector(toggleFileExtensions(_:))))
        showMenu.addItem(menuItem(String(localized: "Hidden items"), #selector(toggleHiddenItems(_:)), key: ".", modifiers: [.command, .shift]))
        show.image = NSImage.symbol("eye")
        show.submenu = showMenu
        menu.addItem(show)
        return menu
    }

    func sortMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, key) in SortKey.allCases.enumerated() {
            let item = menuItem(key.title, #selector(sortByFromMenu(_:)))
            item.tag = index
            item.state = key == viewSettings.sort.key ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let ascending = menuItem(String(localized: "Ascending"), #selector(setSortAscending(_:)))
        ascending.state = viewSettings.sort.ascending ? .on : .off
        menu.addItem(ascending)
        let descending = menuItem(String(localized: "Descending"), #selector(setSortDescending(_:)))
        descending.state = viewSettings.sort.ascending ? .off : .on
        menu.addItem(descending)
        menu.addItem(.separator())
        let group = NSMenuItem(title: String(localized: "Group by"), action: nil, keyEquivalent: "")
        group.image = NSImage.symbol("rectangle.3.group")
        group.submenu = groupByMenu()
        menu.addItem(group)
        return menu
    }

    func groupByMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, key) in GroupKey.allCases.enumerated() {
            let item = menuItem(key.title, #selector(groupByFromMenu(_:)))
            item.tag = index
            item.state = key == viewSettings.groupBy ? .on : .off
            menu.addItem(item)
            if key == .none { menu.addItem(.separator()) }
        }
        return menu
    }

    func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem(String(localized: "Undo"), Selector(("undo:")), symbol: "arrow.uturn.backward", key: "z"))
        menu.items.last?.target = nil
        menu.addItem(.separator())
        let selectAll = NSMenuItem(title: String(localized: "Select all"), action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        selectAll.image = NSImage.symbol("checkmark.circle")
        menu.addItem(selectAll)
        menu.addItem(menuItem(String(localized: "Select none"), #selector(selectNone(_:)), symbol: "circle"))
        menu.addItem(menuItem(String(localized: "Invert selection"), #selector(invertSelection(_:)), symbol: "circle.lefthalf.filled"))
        menu.addItem(.separator())
        menu.addItem(menuItem(String(localized: "Compress to ZIP file"), #selector(compressToZip(_:)), symbol: "doc.zipper"))
        menu.addItem(menuItem(String(localized: "Copy as path"), #selector(copyAsPath(_:)), symbol: "link", key: "c", modifiers: [.command, .option]))
        menu.addItem(menuItem(String(localized: "Open in Terminal"), #selector(openInTerminal(_:)), symbol: "terminal"))
        menu.addItem(.separator())
        menu.addItem(menuItem(String(localized: "Map network drive…"), #selector(mapNetworkDrive(_:)), symbol: "externaldrive.badge.plus"))
        menu.addItem(menuItem(String(localized: "Connect to Server…"), #selector(connectToServer(_:)), symbol: "network", key: "k"))
        menu.addItem(.separator())
        menu.addItem(menuItem(String(localized: "Properties"), #selector(showProperties(_:)), symbol: "info.circle", key: "i"))
        let options = NSMenuItem(title: String(localized: "Options"), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        options.image = NSImage.symbol("gearshape")
        menu.addItem(options)
        return menu
    }

    // MARK: Tree, This Mac and history menus

    func treeMenu(for node: TreeNode) -> NSMenu? {
        guard node.kind != .separator else { return nil }
        let menu = NSMenu()
        if node.kind == .thisMac {
            menu.addItem(menuItem(String(localized: "Open in new tab"), #selector(openThisMacInNewTab(_:))))
            menu.addItem(.separator())
            menu.addItem(menuItem(String(localized: "Map network drive…"), #selector(mapNetworkDrive(_:)), symbol: "externaldrive.badge.plus"))
            return menu
        }
        guard let url = node.url else { return nil }
        let urls = [url]
        menu.addItem(menuItem(String(localized: "Open in new tab"), #selector(openInNewTab(_:)), symbol: "plus.square.on.square", urls: urls))
        menu.addItem(menuItem(String(localized: "Open in new window"), #selector(openInNewWindow(_:)), symbol: "macwindow.badge.plus", urls: urls))
        menu.addItem(.separator())
        if node.kind != .volume {
            menu.addItem(menuItem(String(localized: "Cut"), #selector(cut(_:)), symbol: "scissors", urls: urls))
        }
        menu.addItem(menuItem(String(localized: "Copy"), #selector(copy(_:)), symbol: "doc.on.doc", urls: urls))
        menu.addItem(menuItem(String(localized: "Paste"), #selector(paste(_:)), symbol: "doc.on.clipboard", urls: urls))
        menu.addItem(menuItem(String(localized: "Copy as path"), #selector(copyAsPath(_:)), symbol: "link", urls: urls))
        menu.addItem(.separator())
        if node.kind != .volume {
            menu.addItem(menuItem(Preferences.shared.isPinned(url) ? String(localized: "Unpin from Quick access") : String(localized: "Pin to Quick access"), #selector(togglePin(_:)), symbol: "pin", urls: urls))
        }
        menu.addItem(menuItem(String(localized: "Open in Terminal"), #selector(openInTerminal(_:)), symbol: "terminal", urls: urls))
        menu.addItem(menuItem(String(localized: "Show in Finder"), #selector(showInFinder(_:)), symbol: "macwindow", urls: urls))
        if node.kind == .volume, url.pathKey != "/" {
            menu.addItem(menuItem(String(localized: "Eject"), #selector(ejectVolume(_:)), symbol: "eject", urls: urls))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem(String(localized: "Properties"), #selector(showProperties(_:)), symbol: "info.circle", urls: urls))
        return menu
    }

    /// Right-click on a mapped server that isn't connected.
    func networkLocationMenu(for url: URL) -> NSMenu {
        let menu = NSMenu()
        let connect = NSMenuItem(title: String(localized: "Connect"), action: #selector(connectNetworkLocation(_:)), keyEquivalent: "")
        connect.target = self
        connect.representedObject = url
        connect.attributedTitle = NSAttributedString(string: connect.title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        menu.addItem(connect)
        menu.addItem(.separator())
        let forget = NSMenuItem(title: String(localized: "Remove from This Mac"), action: #selector(forgetNetworkLocation(_:)), keyEquivalent: "")
        forget.target = self
        forget.representedObject = url
        forget.image = NSImage.symbol("minus.circle")
        menu.addItem(forget)
        return menu
    }

    @objc func openThisMacInNewTab(_ sender: Any?) {
        AppDelegate.shared.openTab(.thisMac, from: view.window)
    }

    func historyMenu(back: Bool) -> NSMenu? {
        let entries = back ? Array(history.backStack.reversed()) : Array(history.forwardStack.reversed())
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu()
        for (index, location) in entries.prefix(15).enumerated() {
            let item = NSMenuItem(title: location.title, action: back ? #selector(goBackInHistory(_:)) : #selector(goForwardInHistory(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index + 1
            item.image = Breadcrumbs.icon(for: location)?.menuSized
            menu.addItem(item)
        }
        return menu
    }

    /// The › menu next to each breadcrumb: that folder's subfolders (or the drives, for This Mac).
    func subfolderMenu(for location: Location) -> NSMenu {
        let menu = NSMenu()
        var entries: [(String, URL)] = []
        switch location {
        case .thisMac:
            entries = VolumeService.visibleVolumes().map { ($0.name, $0.url) }
        case .folder(let url):
            let showHidden = Preferences.shared.showHidden
            let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
            let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: FileItem.resourceKeys, options: options)) ?? []
            entries = children
                .compactMap(FileItem.init(url:))
                .filter(\.isFolder)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { ($0.name, $0.folderURL ?? $0.url) }
        case .search:
            break
        }
        if entries.isEmpty {
            let empty = NSMenuItem(title: String(localized: "No folders"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for (title, url) in entries.prefix(200) {
            let item = NSMenuItem(title: title, action: #selector(goToFolder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.image = IconCache.icon(for: url).menuSized
            if let current = self.location.scopeURL, current.isSameItem(as: url) || current.isDescendant(of: url) {
                item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            }
            menu.addItem(item)
        }
        return menu
    }
}
