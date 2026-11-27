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

        let open = menuItem("Open", #selector(openSelection(_:)), urls: urls)
        open.attributedTitle = NSAttributedString(string: "Open", attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        menu.addItem(open)
        if allFolders {
            menu.addItem(menuItem("Open in new tab", #selector(openInNewTab(_:)), symbol: "plus.square.on.square", urls: urls))
            menu.addItem(menuItem("Open in new window", #selector(openInNewWindow(_:)), symbol: "macwindow.badge.plus", urls: urls))
        }
        if allFiles { menu.addItem(openWithItem(for: urls)) }
        if let single, single.isZipArchive {
            menu.addItem(menuItem("Extract All…", #selector(extractAll(_:)), symbol: "archivebox", urls: urls))
        }
        menu.addItem(.separator())

        menu.addItem(menuItem("Cut", #selector(cut(_:)), symbol: "scissors", key: "x", urls: urls))
        menu.addItem(menuItem("Copy", #selector(copy(_:)), symbol: "doc.on.doc", key: "c", urls: urls))
        if let single, single.isFolder {
            menu.addItem(menuItem("Paste", #selector(paste(_:)), symbol: "doc.on.clipboard", key: "v", urls: urls))
        }
        menu.addItem(menuItem("Copy as path", #selector(copyAsPath(_:)), symbol: "link", key: "c", modifiers: [.command, .option], urls: urls))
        menu.addItem(.separator())

        let picker = NSSharingServicePicker(items: urls)
        sharePicker = picker
        menu.addItem(picker.standardShareMenuItem)
        menu.addItem(menuItem("Compress to ZIP file", #selector(compressToZip(_:)), symbol: "doc.zipper", urls: urls))
        if allFolders {
            menu.addItem(menuItem("Pin to Quick access", #selector(togglePin(_:)), symbol: "pin", urls: urls))
        }
        if let single, single.isFolder {
            menu.addItem(menuItem("Open in Terminal", #selector(openInTerminal(_:)), symbol: "terminal", urls: urls))
        }
        menu.addItem(menuItem("Show in Finder", #selector(showInFinder(_:)), symbol: "macwindow", urls: urls))
        if let single, single.url.isVolumeRoot, single.url.pathKey != "/" {
            menu.addItem(menuItem("Eject", #selector(ejectVolume(_:)), symbol: "eject", urls: urls))
        }
        menu.addItem(.separator())

        if items.count >= 1, location.folderURL != nil || location.isSearch {
            let rename = menuItem("Rename", #selector(renameSelection(_:)), symbol: "character.cursor.ibeam", key: functionKey(NSF2FunctionKey), modifiers: [])
            menu.addItem(rename)
        }
        menu.addItem(menuItem("Delete", #selector(moveToTrash(_:)), symbol: "trash", key: "\u{8}", urls: urls))
        menu.addItem(.separator())
        menu.addItem(menuItem("Properties", #selector(showProperties(_:)), symbol: "info.circle", key: "i", urls: urls))
        return menu
    }

    private func openWithItem(for urls: [URL]) -> NSMenuItem {
        let item = NSMenuItem(title: "Open with", action: nil, keyEquivalent: "")
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
        let other = NSMenuItem(title: "Choose another app…", action: #selector(openWithOtherApplication(_:)), keyEquivalent: "")
        other.target = self
        other.representedObject = urls
        submenu.addItem(other)
        item.submenu = submenu
        return item
    }

    // MARK: Background context menu

    func backgroundMenu() -> NSMenu {
        let menu = NSMenu()
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.image = NSImage.symbol("square.grid.2x2")
        viewItem.submenu = viewMenu()
        menu.addItem(viewItem)
        let sortItem = NSMenuItem(title: "Sort by", action: nil, keyEquivalent: "")
        sortItem.image = NSImage.symbol("arrow.up.arrow.down")
        sortItem.submenu = sortMenu()
        menu.addItem(sortItem)
        menu.addItem(menuItem("Refresh", #selector(refresh(_:)), symbol: "arrow.clockwise", key: functionKey(NSF5FunctionKey), modifiers: []))
        menu.addItem(.separator())

        menu.addItem(menuItem("Paste", #selector(paste(_:)), symbol: "doc.on.clipboard", key: "v"))
        let undoManager = FileOperationService.shared.undoManager
        if undoManager.canUndo {
            let undo = NSMenuItem(title: undoManager.undoMenuItemTitle, action: Selector(("undo:")), keyEquivalent: "z")
            undo.image = NSImage.symbol("arrow.uturn.backward")
            menu.addItem(undo)
        }
        menu.addItem(.separator())

        let newItem = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        newItem.image = NSImage.symbol("plus.circle")
        newItem.submenu = newMenu()
        menu.addItem(newItem)
        menu.addItem(.separator())

        if let folder = location.folderURL {
            menu.addItem(menuItem("Open in Terminal", #selector(openInTerminal(_:)), symbol: "terminal"))
            menu.addItem(menuItem("Show in Finder", #selector(showInFinder(_:)), symbol: "macwindow", urls: [folder]))
            menu.addItem(.separator())
            menu.addItem(menuItem("Properties", #selector(showProperties(_:)), symbol: "info.circle", key: "i", urls: [folder]))
        }
        return menu
    }

    // MARK: Drop-down menus (also used by the command bar)

    func newMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Folder", #selector(newFolder(_:)), symbol: "folder.badge.plus", key: "n", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(menuItem("Text Document", #selector(newTextDocument(_:)), symbol: "doc.text", key: "n", modifiers: [.command, .option]))
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
        let show = NSMenuItem(title: "Show", action: nil, keyEquivalent: "")
        let showMenu = NSMenu()
        showMenu.addItem(menuItem("Navigation pane", #selector(toggleNavigationPane(_:))))
        showMenu.addItem(menuItem("Preview pane", #selector(togglePreviewPane(_:)), key: "p", modifiers: [.option]))
        showMenu.addItem(.separator())
        showMenu.addItem(menuItem("File name extensions", #selector(toggleFileExtensions(_:))))
        showMenu.addItem(menuItem("Hidden items", #selector(toggleHiddenItems(_:)), key: ".", modifiers: [.command, .shift]))
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
        let ascending = menuItem("Ascending", #selector(setSortAscending(_:)))
        ascending.state = viewSettings.sort.ascending ? .on : .off
        menu.addItem(ascending)
        let descending = menuItem("Descending", #selector(setSortDescending(_:)))
        descending.state = viewSettings.sort.ascending ? .off : .on
        menu.addItem(descending)
        return menu
    }

    func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Undo", Selector(("undo:")), symbol: "arrow.uturn.backward", key: "z"))
        menu.items.last?.target = nil
        menu.addItem(.separator())
        let selectAll = NSMenuItem(title: "Select all", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        selectAll.image = NSImage.symbol("checkmark.circle")
        menu.addItem(selectAll)
        menu.addItem(menuItem("Select none", #selector(selectNone(_:)), symbol: "circle"))
        menu.addItem(menuItem("Invert selection", #selector(invertSelection(_:)), symbol: "circle.lefthalf.filled"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Compress to ZIP file", #selector(compressToZip(_:)), symbol: "doc.zipper"))
        menu.addItem(menuItem("Copy as path", #selector(copyAsPath(_:)), symbol: "link", key: "c", modifiers: [.command, .option]))
        menu.addItem(menuItem("Open in Terminal", #selector(openInTerminal(_:)), symbol: "terminal"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Properties", #selector(showProperties(_:)), symbol: "info.circle", key: "i"))
        let options = NSMenuItem(title: "Options", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        options.image = NSImage.symbol("gearshape")
        menu.addItem(options)
        return menu
    }

    // MARK: Tree, This Mac and history menus

    func treeMenu(for node: TreeNode) -> NSMenu? {
        guard node.kind != .separator else { return nil }
        let menu = NSMenu()
        if node.kind == .thisMac {
            menu.addItem(menuItem("Open in new tab", #selector(openThisMacInNewTab(_:))))
            return menu
        }
        guard let url = node.url else { return nil }
        let urls = [url]
        menu.addItem(menuItem("Open in new tab", #selector(openInNewTab(_:)), symbol: "plus.square.on.square", urls: urls))
        menu.addItem(menuItem("Open in new window", #selector(openInNewWindow(_:)), symbol: "macwindow.badge.plus", urls: urls))
        menu.addItem(.separator())
        if node.kind != .volume {
            menu.addItem(menuItem("Cut", #selector(cut(_:)), symbol: "scissors", urls: urls))
        }
        menu.addItem(menuItem("Copy", #selector(copy(_:)), symbol: "doc.on.doc", urls: urls))
        menu.addItem(menuItem("Paste", #selector(paste(_:)), symbol: "doc.on.clipboard", urls: urls))
        menu.addItem(menuItem("Copy as path", #selector(copyAsPath(_:)), symbol: "link", urls: urls))
        menu.addItem(.separator())
        if node.kind != .volume {
            menu.addItem(menuItem(Preferences.shared.isPinned(url) ? "Unpin from Quick access" : "Pin to Quick access", #selector(togglePin(_:)), symbol: "pin", urls: urls))
        }
        menu.addItem(menuItem("Open in Terminal", #selector(openInTerminal(_:)), symbol: "terminal", urls: urls))
        menu.addItem(menuItem("Show in Finder", #selector(showInFinder(_:)), symbol: "macwindow", urls: urls))
        if node.kind == .volume, url.pathKey != "/" {
            menu.addItem(menuItem("Eject", #selector(ejectVolume(_:)), symbol: "eject", urls: urls))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Properties", #selector(showProperties(_:)), symbol: "info.circle", urls: urls))
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
            entries = VolumeService.mountedVolumes().map { ($0.name, $0.url) }
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
            let empty = NSMenuItem(title: "No folders", action: nil, keyEquivalent: "")
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
