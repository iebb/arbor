import AppKit
import Quartz

/// Every command a user can run, whether from the menu bar, command bar, a context menu or a shortcut.
/// Context-menu items carry their target URLs in `representedObject` as `[URL]`.
extension BrowserViewController: NSMenuItemValidation {
    // MARK: Targets

    /// The items a command acts on: the context-menu target, the tree's folder when the tree has focus,
    /// or the selection in the folder view.
    func targetURLs(_ sender: Any?) -> [URL] {
        if let item = sender as? NSMenuItem, let urls = item.representedObject as? [URL] { return urls }
        if navigationPane.hasFocus {
            guard let node = navigationPane.selectedNode, node.kind != .thisMac, let url = node.url else { return [] }
            return [url]
        }
        return selectedContentItems.map(\.url)
    }

    func targetItems(_ sender: Any?) -> [FileItem] {
        targetURLs(sender).compactMap(FileItem.init(url:))
    }

    /// Where Paste puts things: a folder you right-clicked, the tree's folder when it has focus, or the current folder.
    func pasteDestination(_ sender: Any?) -> URL? {
        if let item = sender as? NSMenuItem, let urls = item.representedObject as? [URL] {
            guard urls.count == 1, let folder = FileItem(url: urls[0])?.folderURL else { return nil }
            return folder
        }
        if navigationPane.hasFocus, let url = navigationPane.selectedURL { return url }
        return location.folderURL
    }

    private func isRemovable(_ url: URL) -> Bool {
        !url.isVolumeRoot && url.pathKey != FileManager.default.realHomeDirectory.pathKey
    }

    // MARK: Validation

    func canPerform(_ action: Selector?, sender: Any? = nil) -> Bool {
        guard let action else { return false }
        let targets = targetURLs(sender)
        switch action {
        case #selector(copy(_:)), #selector(copyAsPath(_:)), #selector(showInFinder(_:)), #selector(openSelection(_:)):
            return !targets.isEmpty
        case #selector(cut(_:)), #selector(moveToTrash(_:)), #selector(deletePermanently(_:)):
            return !targets.isEmpty && targets.allSatisfy(isRemovable)
        case #selector(duplicate(_:)):
            return location.folderURL != nil && !targets.isEmpty && targets.allSatisfy(isRemovable)
        case #selector(paste(_:)):
            return pasteDestination(sender) != nil && FileClipboard.shared.hasFiles
        case #selector(renameSelection(_:)):
            return !navigationPane.hasFocus && presenter != nil && !(presenter?.selectedItems.isEmpty ?? true)
                && (presenter?.selectedItems.allSatisfy { isRemovable($0.url) } ?? false)
        case #selector(newFolder(_:)), #selector(newTextDocument(_:)):
            return location.folderURL != nil
        case #selector(compressToZip(_:)):
            return !targets.isEmpty && Set(targets.map { $0.parentFolder.pathKey }).count == 1 && targets.allSatisfy(isRemovable)
        case #selector(extractAll(_:)):
            return targets.count == 1 && FileItem(url: targets[0])?.isZipArchive == true
        case #selector(openInNewTab(_:)), #selector(openInNewWindow(_:)), #selector(togglePin(_:)):
            return !targets.isEmpty && targets.allSatisfy { FileItem(url: $0)?.isFolder == true }
        case #selector(openInTerminal(_:)):
            return terminalFolder(sender) != nil
        case #selector(showProperties(_:)):
            return !targets.isEmpty || location.scopeURL != nil
        case #selector(ejectVolume(_:)):
            return targets.count == 1 && targets[0].isVolumeRoot && targets[0].pathKey != "/"
        case #selector(goBackAction(_:)):
            return history.canGoBack
        case #selector(goForwardAction(_:)):
            return history.canGoForward
        case #selector(goUpAction(_:)):
            return parentLocation(of: location) != nil
        case #selector(selectNone(_:)), #selector(invertSelection(_:)):
            return presenter != nil && !items.isEmpty
        case #selector(focusSearch(_:)):
            return location.scopeURL != nil
        case #selector(quickLook(_:)):
            return !selectedContentItems.isEmpty
        default:
            return true
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(setViewModeFromMenu(_:)):
            menuItem.state = ViewMode.allCases.indices.contains(menuItem.tag) && ViewMode.allCases[menuItem.tag] == viewSettings.viewMode ? .on : .off
            return !location.isThisMac
        case #selector(sortByFromMenu(_:)):
            menuItem.state = SortKey.allCases.indices.contains(menuItem.tag) && SortKey.allCases[menuItem.tag] == viewSettings.sort.key ? .on : .off
            return !location.isThisMac
        case #selector(groupByFromMenu(_:)):
            menuItem.state = GroupKey.allCases.indices.contains(menuItem.tag) && GroupKey.allCases[menuItem.tag] == viewSettings.groupBy ? .on : .off
            return !location.isThisMac
        case #selector(setSortAscending(_:)):
            menuItem.state = viewSettings.sort.ascending ? .on : .off
            return !location.isThisMac
        case #selector(setSortDescending(_:)):
            menuItem.state = viewSettings.sort.ascending ? .off : .on
            return !location.isThisMac
        case #selector(toggleNavigationPane(_:)):
            menuItem.state = navigationSplitItem.isCollapsed ? .off : .on
            return true
        case #selector(togglePreviewPane(_:)):
            menuItem.state = previewSplitItem.isCollapsed ? .off : .on
            return true
        case #selector(toggleFileExtensions(_:)):
            menuItem.state = Preferences.shared.showExtensions ? .on : .off
            return true
        case #selector(toggleHiddenItems(_:)):
            menuItem.state = Preferences.shared.showHidden ? .on : .off
            return true
        case #selector(toggleOption(_:)):
            guard let raw = menuItem.representedObject as? String, let option = FolderOption(rawValue: raw) else { return false }
            menuItem.state = Preferences.shared[option] ? .on : .off
            return true
        case #selector(togglePin(_:)):
            let urls = targetURLs(menuItem)
            menuItem.title = !urls.isEmpty && urls.allSatisfy(Preferences.shared.isPinned) ? "Unpin from Quick access" : "Pin to Quick access"
            return canPerform(menuItem.action, sender: menuItem)
        default:
            return canPerform(menuItem.action, sender: menuItem)
        }
    }

    // MARK: Open

    func open(_ items: [FileItem], inNewTab: Bool = false) {
        let folders = items.compactMap(\.folderURL)
        let files = items.filter { !$0.isFolder }.map(\.url)
        for file in files {
            NSWorkspace.shared.open(file)
            if Preferences.shared[.showRecentFiles] { RecentItems.shared.recordFileOpen(file) }
        }
        if !inNewTab, Preferences.shared[.openFoldersInNewWindow] {
            // "Open each folder in its own window".
            for folder in folders { AppDelegate.shared.openWindow(.folder(folder)) }
        } else if inNewTab || folders.count > 1 {
            for folder in folders { AppDelegate.shared.openTab(.folder(folder), from: view.window) }
        } else if let folder = folders.first {
            navigate(to: .folder(folder))
        }
    }

    @objc func openSelection(_ sender: Any?) {
        open(targetItems(sender))
    }

    @objc func openInNewTab(_ sender: Any?) {
        for folder in targetItems(sender).compactMap(\.folderURL) {
            AppDelegate.shared.openTab(.folder(folder), from: view.window)
        }
    }

    @objc func openInNewWindow(_ sender: Any?) {
        for folder in targetItems(sender).compactMap(\.folderURL) {
            AppDelegate.shared.openWindow(.folder(folder))
        }
    }

    @objc func openWithApplication(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [URL], let app = info.first else { return }
        NSWorkspace.shared.open(Array(info.dropFirst()), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func openWithOtherApplication(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL], !urls.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = String(localized: "Open")
        panel.message = String(localized: "Choose an app to open “\(urls[0].lastPathComponent)”")
        guard panel.runModal() == .OK, let app = panel.url else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Clipboard

    @objc func copy(_ sender: Any?) {
        FileClipboard.shared.write(targetURLs(sender), cut: false)
    }

    @objc func cut(_ sender: Any?) {
        FileClipboard.shared.write(targetURLs(sender), cut: true)
    }

    @objc func paste(_ sender: Any?) {
        guard let destination = pasteDestination(sender) else { return }
        let urls = FileClipboard.shared.fileURLs
        guard !urls.isEmpty else { return }
        let isCut = FileClipboard.shared.isCut
        FileOperationService.shared.transfer(urls, to: destination, move: isCut, window: view.window) { [weak self] created in
            if isCut, !created.isEmpty { FileClipboard.shared.clearAfterMove() }
            self?.selectAfterOperation(created, in: destination)
        }
    }

    @objc func duplicate(_ sender: Any?) {
        guard let folder = location.folderURL else { return }
        FileOperationService.shared.transfer(targetURLs(sender), to: folder, move: false, window: view.window) { [weak self] created in
            self?.selectAfterOperation(created, in: folder)
        }
    }

    /// Explorer's "Copy as path": each path in quotes, one per line.
    @objc func copyAsPath(_ sender: Any?) {
        let urls = targetURLs(sender)
        guard !urls.isEmpty else { return }
        FileClipboard.shared.copyText(urls.map { "\"\($0.path)\"" }.joined(separator: "\n"))
    }

    // MARK: Rename

    @objc func renameSelection(_ sender: Any?) {
        guard let presenter, let first = presenter.selectedItems.first else { return }
        renameBatch = presenter.selectedItems.count > 1 ? presenter.selectedItems : []
        presenter.beginRename(first.url)
    }

    /// Commits an inline rename (single or Explorer-style batch).
    func commitRename(of item: FileItem, to typedName: String) -> Bool {
        let showExtensions = Preferences.shared.showExtensions
        var newName = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.hidesExtension(showExtensions: showExtensions) {
            newName = NameGenerator.join(newName, item.fileExtension)
        }

        let batch = renameBatch
        renameBatch = []
        if batch.count > 1, batch.contains(item) {
            let base = NameGenerator.split(newName, isFolder: item.isFolder).base
            let renamed = FileOperationService.shared.batchRename(batch.map(\.url), base: base, window: view.window)
            applyLocalRenames(renamed)
            return !renamed.isEmpty
        }

        // Explorer warns only when the extension was visible (and so editable) and actually changed.
        if !item.isFolder, !item.hidesExtension(showExtensions: showExtensions) {
            let oldExtension = item.fileExtension.lowercased()
            let newExtension = NameGenerator.split(newName, isFolder: false).ext?.lowercased() ?? ""
            if oldExtension != newExtension, !confirmExtensionChange() {
                return false
            }
        }

        guard let renamed = FileOperationService.shared.rename(item.url, to: newName, window: view.window) else { return false }
        applyLocalRenames([(from: item.url, to: renamed)])
        return true
    }

    private func confirmExtensionChange() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename")
        alert.informativeText = String(localized: "If you change a file name extension, the file might become unusable.\n\nAre you sure you want to change it?")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Yes"))
        alert.addButton(withTitle: String(localized: "No"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Delete

    @objc func moveToTrash(_ sender: Any?) {
        let urls = targetURLs(sender).filter { isRemovable($0) }
        guard !urls.isEmpty else { return }
        selectNeighbor(afterRemoving: urls)
        FileOperationService.shared.trash(urls, window: view.window)
    }

    @objc func deletePermanently(_ sender: Any?) {
        let urls = targetURLs(sender).filter { isRemovable($0) }
        guard !urls.isEmpty else { return }
        selectNeighbor(afterRemoving: urls)
        FileOperationService.shared.deletePermanently(urls, window: view.window)
    }

    /// After deleting, Explorer selects the next item so you can keep going with the keyboard.
    private func selectNeighbor(afterRemoving urls: [URL]) {
        let removed = Set(urls.map(\.pathKey))
        guard let lastIndex = items.lastIndex(where: { removed.contains($0.url.pathKey) }) else { return }
        let after = items[(lastIndex + 1)...].first { !removed.contains($0.url.pathKey) }
        let before = items[..<lastIndex].last { !removed.contains($0.url.pathKey) }
        if let next = after ?? before { setPendingSelection([next.url]) }
    }

    // MARK: New

    @objc func newFolder(_ sender: Any?) {
        guard let folder = location.folderURL,
              let created = FileOperationService.shared.newFolder(in: folder, window: view.window) else { return }
        presenter?.focusContent()
        selectAfterOperation([created], in: folder, rename: created)
    }

    @objc func newTextDocument(_ sender: Any?) {
        guard let folder = location.folderURL,
              let created = FileOperationService.shared.newTextDocument(in: folder, window: view.window) else { return }
        presenter?.focusContent()
        selectAfterOperation([created], in: folder, rename: created)
    }

    // MARK: ZIP

    @objc func compressToZip(_ sender: Any?) {
        let urls = targetURLs(sender)
        guard let folder = urls.first?.parentFolder else { return }
        FileOperationService.shared.compress(urls, window: view.window) { [weak self] archive in
            guard let archive else { return }
            self?.selectAfterOperation([archive], in: folder, rename: archive)
        }
    }

    @objc func extractAll(_ sender: Any?) {
        guard let archive = targetURLs(sender).first else { return }
        FileOperationService.shared.extract(archive, window: view.window) { [weak self] folder in
            guard let folder else { return }
            self?.selectAfterOperation([folder], in: archive.parentFolder)
        }
    }

    // MARK: Elsewhere

    private func terminalFolder(_ sender: Any?) -> URL? {
        let targets = targetItems(sender)
        if targets.count == 1, let folder = targets[0].folderURL { return folder }
        if let item = sender as? NSMenuItem, item.representedObject != nil { return nil }
        return location.folderURL
    }

    @objc func openInTerminal(_ sender: Any?) {
        guard let folder = terminalFolder(sender),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func showInFinder(_ sender: Any?) {
        let urls = targetURLs(sender)
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [location.scopeURL].compactMap { $0 } : urls)
    }

    @objc func showProperties(_ sender: Any?) {
        var urls = targetURLs(sender)
        if urls.isEmpty, let folder = location.scopeURL { urls = [folder] }
        guard !urls.isEmpty else { return }
        PropertiesWindowController.show(for: urls)
    }

    @objc func togglePin(_ sender: Any?) {
        let folders = targetItems(sender).compactMap(\.folderURL)
        guard !folders.isEmpty else { return }
        if folders.allSatisfy(Preferences.shared.isPinned) {
            folders.forEach(Preferences.shared.unpin)
        } else {
            folders.forEach(Preferences.shared.pin)
        }
    }

    @objc func ejectVolume(_ sender: Any?) {
        guard let volume = targetURLs(sender).first else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            NotificationCenter.default.post(name: .arborVolumesChanged, object: nil)
        } catch {
            FileOperationService.shared.present(error, window: view.window)
        }
    }

    // MARK: Network

    /// Finder's ⌘K: connect once and open the share.
    @objc func connectToServer(_ sender: Any?) {
        guard let answer = ConnectToServerDialog.run(mapping: false) else { return }
        connect(to: answer.url, remember: answer.remember, reconnect: answer.reconnect)
    }

    /// Explorer's "Map network drive": connect and keep the server on This Mac.
    @objc func mapNetworkDrive(_ sender: Any?) {
        guard let answer = ConnectToServerDialog.run(mapping: true) else { return }
        connect(to: answer.url, remember: answer.remember, reconnect: answer.reconnect)
    }

    func connect(to url: URL, remember: Bool, reconnect: Bool) {
        guard NetworkLocations.isMountable(url) else {
            NSWorkspace.shared.open(url)
            return
        }
        if remember { NetworkLocations.save(NetworkLocation(address: url.absoluteString, reconnectAtLaunch: reconnect)) }
        statusBar.setBusy(true)
        NetworkLocations.connect(url) { [weak self] result in
            guard let self else { return }
            self.statusBar.setBusy(false)
            switch result {
            case .success(let mountPoint):
                self.navigate(to: .folder(mountPoint))
            case .failure(let error as CocoaError) where error.code == .userCancelled:
                break
            case .failure(let error):
                FileOperationService.shared.present(error, window: self.view.window)
            }
        }
    }

    @objc func forgetNetworkLocation(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NetworkLocations.forget(url.absoluteString)
    }

    @objc func connectNetworkLocation(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        connect(to: url, remember: false, reconnect: false)
    }

    // MARK: Selection

    @objc func selectNone(_ sender: Any?) {
        presenter?.selectNoItems()
    }

    @objc func invertSelection(_ sender: Any?) {
        presenter?.invertSelection()
    }

    // MARK: Navigation commands

    @objc func goBackAction(_ sender: Any?) { goBack() }
    @objc func goForwardAction(_ sender: Any?) { goForward() }
    @objc func goUpAction(_ sender: Any?) { goUp() }
    @objc func goToThisMac(_ sender: Any?) { navigate(to: .thisMac) }

    /// Go menu items carry the destination folder URL in `representedObject`.
    @objc func goToFolder(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { navigate(to: .folder(url)) }
    }

    @objc func goBackInHistory(_ sender: NSMenuItem) { goBack(steps: sender.tag) }
    @objc func goForwardInHistory(_ sender: NSMenuItem) { goForward(steps: sender.tag) }

    @objc func refresh(_ sender: Any?) {
        IconCache.invalidate()
        reload()
        navigationPane.refreshAllLoaded()
    }

    @objc func focusAddressBar(_ sender: Any?) {
        addressBar.beginEditing()
    }

    @objc func focusSearch(_ sender: Any?) {
        addressBar.focusSearch()
    }

    // MARK: View commands

    @objc func setViewModeFromMenu(_ sender: NSMenuItem) {
        guard ViewMode.allCases.indices.contains(sender.tag) else { return }
        setViewMode(ViewMode.allCases[sender.tag])
    }

    @objc func sortByFromMenu(_ sender: NSMenuItem) {
        guard SortKey.allCases.indices.contains(sender.tag) else { return }
        let key = SortKey.allCases[sender.tag]
        var sort = viewSettings.sort
        if sort.key == key { sort.ascending.toggle() } else { sort = SortOrder(key: key, ascending: key == .name || key == .type) }
        setSort(sort)
    }

    @objc func groupByFromMenu(_ sender: NSMenuItem) {
        guard GroupKey.allCases.indices.contains(sender.tag) else { return }
        setGroupBy(GroupKey.allCases[sender.tag])
    }

    @objc func setSortAscending(_ sender: Any?) {
        setSort(SortOrder(key: viewSettings.sort.key, ascending: true))
    }

    @objc func setSortDescending(_ sender: Any?) {
        setSort(SortOrder(key: viewSettings.sort.key, ascending: false))
    }

    @objc func toggleNavigationPane(_ sender: Any?) {
        setNavigationPaneVisible(navigationSplitItem.isCollapsed)
    }

    @objc func togglePreviewPane(_ sender: Any?) {
        setPreviewPaneVisible(previewSplitItem.isCollapsed)
    }

    @objc func toggleFileExtensions(_ sender: Any?) {
        Preferences.shared.showExtensions.toggle()
    }

    @objc func toggleHiddenItems(_ sender: Any?) {
        Preferences.shared.showHidden.toggle()
    }

    /// View › Show items that flip one setting (`representedObject` is the option's raw value).
    @objc func toggleOption(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let option = FolderOption(rawValue: raw) else { return }
        Preferences.shared.toggle(option)
    }

    // MARK: Quick Look

    @objc func quickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Share

    func share(_ urls: [URL], from view: NSView) {
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        sharePicker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}
