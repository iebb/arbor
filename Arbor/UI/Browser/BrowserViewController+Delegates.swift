import AppKit
import Quartz

// MARK: - Explorer keyboard map

extension BrowserViewController {
    /// Handles Explorer's keys before AppKit does. Returns true when the key was used.
    /// Called from the app-wide key monitor for the browser window that has focus.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let responder = view.window?.firstResponder
        let editingText = responder is NSText
        let inContent = presenter?.containsFirstResponder == true || (location.isThisMac && !navigationPane.hasFocus && !editingText)
        let code = event.keyCode

        // Keys that work everywhere, even while typing.
        switch (code, flags) {
        case (KeyCode.f3, []):
            focusSearch(nil)
            return true
        case (KeyCode.f4, []):
            focusAddressBar(nil)
            return true
        case (KeyCode.f5, []):
            refresh(nil)
            return true
        default:
            break
        }
        guard !editingText else { return false }

        switch (code, flags) {
        case (KeyCode.x, [.command]):
            guard canPerform(#selector(cut(_:))) else { return false }
            cut(nil)
        case (KeyCode.c, [.command]):
            guard canPerform(#selector(copy(_:))) else { return false }
            copy(nil)
        case (KeyCode.v, [.command]):
            guard canPerform(#selector(paste(_:))) else { return false }
            paste(nil)
        case (KeyCode.escape, []):
            guard FileClipboard.shared.isCut else { return false }
            FileClipboard.shared.cancelCut()
        case (KeyCode.f2, []):
            renameSelection(nil)
        case (KeyCode.d, [.option]), (KeyCode.f4, [.option]):
            focusAddressBar(nil)
        case (KeyCode.left, [.option]):
            goBack()
        case (KeyCode.right, [.option]):
            goForward()
        case (KeyCode.up, [.option]):
            goUp()
        case (KeyCode.backspace, []):
            if Preferences.shared.backspaceGoesBack { goBack() } else { moveToTrash(nil) }
        case (KeyCode.forwardDelete, []):
            moveToTrash(nil)
        case (KeyCode.forwardDelete, [.shift]), (KeyCode.backspace, [.command, .option]):
            deletePermanently(nil)
        case (KeyCode.returnKey, []), (KeyCode.enter, []):
            if location.isThisMac, !navigationPane.hasFocus {
                thisMacController.openSelection()
            } else if inContent {
                open(selectedContentItems)
            } else if navigationPane.hasFocus {
                presenter?.focusContent()
            } else {
                return false
            }
        case (KeyCode.returnKey, [.option]):
            showProperties(nil)
        case (KeyCode.p, [.option]):
            togglePreviewPane(nil)
        case (KeyCode.p, [.option, .shift]):
            toggleDetailsPane(nil)
        case (KeyCode.n, [.control, .shift]):
            newFolder(nil)
        case (KeyCode.space, []):
            if Date().timeIntervalSince(lastTypeSelect) < 1 { return false }  // part of type-to-select
            guard !selectedContentItems.isEmpty else { return false }
            quickLook(nil)
        case (KeyCode.home, []) where inContent:
            presenter?.selectEdge(last: false)
        case (KeyCode.end, []) where inContent:
            presenter?.selectEdge(last: true)
        default:
            if flags == [.control, .shift], let index = KeyCode.digits.firstIndex(of: code) {
                setViewMode(ViewMode.allCases[index])
                return true
            }
            if inContent, flags.isSubset(of: [.shift]), let characters = event.characters, !characters.isEmpty,
               characters.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.punctuationCharacters).contains($0) }) {
                // "When typing into list view: Automatically type into the Search Box".
                if Preferences.shared[.typeIntoSearchBox], location.scopeURL != nil {
                    addressBar.focusSearch()
                    if let editor = addressBar.searchField.currentEditor() as? NSTextView {
                        editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
                        editor.insertText(characters, replacementRange: editor.selectedRange)
                    }
                    return true
                }
                lastTypeSelect = Date()
            }
            return false
        }
        return true
    }
}

// MARK: - Folder view

extension BrowserViewController: ItemPresenterDelegate {
    func presenterSelectionDidChange(_ presenter: ItemPresenter) {
        selectionDidChange()
    }

    func presenter(_ presenter: ItemPresenter, open items: [FileItem]) {
        open(items)
    }

    func presenter(_ presenter: ItemPresenter, openInNewTab items: [FileItem]) {
        open(items, inNewTab: true)
    }

    func presenter(_ presenter: ItemPresenter, menuFor items: [FileItem]) -> NSMenu? {
        itemMenu(for: items)
    }

    func presenter(_ presenter: ItemPresenter, rename item: FileItem, to newName: String) -> Bool {
        commitRename(of: item, to: newName)
    }

    func presenter(_ presenter: ItemPresenter, didChangeSort sort: SortOrder) {
        setSort(sort)
    }

    func presenter(_ presenter: ItemPresenter, dropOperationFor info: NSDraggingInfo, onto folder: FileItem?) -> NSDragOperation {
        guard let destination = folder?.folderURL ?? location.folderURL else { return [] }
        return DragDrop.operation(for: info, destination: destination)
    }

    func presenter(_ presenter: ItemPresenter, acceptDrop info: NSDraggingInfo, onto folder: FileItem?) -> Bool {
        guard let destination = folder?.folderURL ?? location.folderURL else { return false }
        return acceptDrop(info, into: destination)
    }

    func acceptDrop(_ info: NSDraggingInfo, into destination: URL) -> Bool {
        let operation = DragDrop.operation(for: info, destination: destination)
        let urls = DragDrop.fileURLs(from: info)
        guard operation != [], !urls.isEmpty else { return false }
        // Defer so any conflict prompt doesn't run inside the drag session.
        DispatchQueue.main.async { [weak self] in
            FileOperationService.shared.transfer(urls, to: destination, move: operation == .move, window: self?.view.window) { created in
                self?.selectAfterOperation(created, in: destination)
            }
        }
        return true
    }
}

// MARK: - Navigation pane

extension BrowserViewController: NavigationPaneDelegate {
    func navigationPane(_ pane: NavigationPaneController, didSelect location: Location) {
        navigate(to: location)
    }

    func navigationPane(_ pane: NavigationPaneController, openInNewTab location: Location) {
        AppDelegate.shared.openTab(location, from: view.window)
    }

    func navigationPane(_ pane: NavigationPaneController, menuFor node: TreeNode) -> NSMenu? {
        treeMenu(for: node)
    }

    func navigationPane(_ pane: NavigationPaneController, dropOperationFor info: NSDraggingInfo, into folder: URL) -> NSDragOperation {
        DragDrop.operation(for: info, destination: folder)
    }

    func navigationPane(_ pane: NavigationPaneController, acceptDrop info: NSDraggingInfo, into folder: URL) -> Bool {
        acceptDrop(info, into: folder)
    }
}

// MARK: - This Mac

extension BrowserViewController: ThisMacDelegate {
    func thisMac(_ controller: ThisMacViewController, open url: URL) {
        if url.isFileURL { navigate(to: .folder(url)) } else { connect(to: url, remember: false, reconnect: false) }
    }

    func thisMac(_ controller: ThisMacViewController, menuFor url: URL?, isVolume: Bool) -> NSMenu? {
        guard let url else { return nil }
        if !url.isFileURL { return networkLocationMenu(for: url) }
        guard let item = FileItem(url: url) else { return nil }
        return itemMenu(for: [item])
    }

    func thisMacSelectionDidChange(_ controller: ThisMacViewController) {
        selectionDidChange()
    }
}

// MARK: - Address bar

extension BrowserViewController: AddressBarDelegate {
    func addressBarGoBack() { goBack() }
    func addressBarGoForward() { goForward() }
    func addressBarGoUp() { goUp() }
    func addressBarRefresh() { refresh(nil) }

    func addressBarNavigate(to location: Location) {
        navigate(to: location)
    }

    func addressBarSubmit(path: String) -> Bool {
        // \\server\share and smb://server/share connect to the server, as in Explorer.
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\\\\") || trimmed.range(of: "^(smb|cifs|afp|nfs|webdav)://", options: [.regularExpression, .caseInsensitive]) != nil,
           let url = NetworkLocations.normalizedURL(trimmed) {
            connect(to: url, remember: false, reconnect: false)
            return true
        }
        switch PathResolver.resolve(path, relativeTo: location.folderURL) {
        case .location(let destination):
            navigate(to: destination)
            presenter?.focusContent()
            return true
        case .file(let url):
            NSWorkspace.shared.open(url)
            return true
        case .web(let url):
            NSWorkspace.shared.open(url)
            return true
        case .notFound(let text):
            FileOperationService.shared.showAlert(
                message: String(localized: "Arbor can't find “\(text)”."),
                info: String(localized: "Check the spelling and try again."),
                window: view.window
            )
            return false
        }
    }

    func addressBarDidFinishEditing() {
        presenter?.focusContent()
    }

    func addressBarSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if case .search(let root, _) = location {
                if history.canGoBack { goBack() } else { navigate(to: .folder(root)) }
            }
            return
        }
        switch location {
        case .search(let root, _):
            history.replaceCurrent(with: .search(root: root, query: trimmed))
            displayLocation()
        case .folder(let root):
            navigate(to: .search(root: root, query: trimmed))
        case .thisMac:
            break
        }
    }

    func addressBarHistoryMenu(back: Bool) -> NSMenu? {
        historyMenu(back: back)
    }

    func addressBarSubfolderMenu(for location: Location) -> NSMenu {
        subfolderMenu(for: location)
    }
}

// MARK: - Command bar

extension BrowserViewController: CommandBarDelegate {
    func commandBarNewMenu() -> NSMenu { newMenu() }
    func commandBarSortMenu() -> NSMenu { sortMenu() }
    func commandBarViewMenu() -> NSMenu { viewMenu() }
    func commandBarMoreMenu() -> NSMenu { moreMenu() }
    func commandBarCut() { cut(nil) }
    func commandBarCopy() { copy(nil) }
    func commandBarPaste() { paste(nil) }
    func commandBarRename() { renameSelection(nil) }
    func commandBarShare(from button: NSButton) { share(targetURLs(nil), from: button) }
    func commandBarDelete() { moveToTrash(nil) }
    func commandBarTogglePreview() { togglePreviewPane(nil) }
    func commandBarToggleDetails() { toggleDetailsPane(nil) }
}

// MARK: - Quick Look (Space)

extension BrowserViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLookURLs = selectedContentItems.map(\.url)
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookURLs[index] as NSURL
    }

    /// Arrow keys in the Quick Look panel move the selection in the folder view.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, let presenter else { return false }
        if [KeyCode.up, KeyCode.down, KeyCode.left, KeyCode.right].contains(event.keyCode) {
            presenter.keyView.keyDown(with: event)
            return true
        }
        return false
    }
}
