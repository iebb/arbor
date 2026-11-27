import AppKit

/// The menu bar. Mac shortcuts are listed in menus; Explorer's (F2, Alt+←, Backspace…) also work —
/// see `BrowserViewController.handleKeyDown`.
enum MainMenu {
    private typealias B = BrowserViewController

    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("Arbor", appMenu()))
        main.addItem(submenu(String(localized: "File"), fileMenu()))
        main.addItem(submenu(String(localized: "Edit"), editMenu()))
        main.addItem(submenu(String(localized: "View"), viewMenu()))
        main.addItem(submenu(String(localized: "Go"), goMenu()))
        let window = windowMenu()
        main.addItem(submenu(String(localized: "Window"), window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenu(String(localized: "Help"), help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        menu.title = title
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command], tag: Int = 0, object: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        item.representedObject = object
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(String(localized: "About Arbor"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Settings…"), #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        let services = NSMenu()
        menu.addItem(submenu(String(localized: "Services"), services))
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Hide Arbor"), #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item(String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit Arbor"), #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(String(localized: "New Window"), #selector(AppDelegate.newWindow(_:)), "n"))
        menu.addItem(item(String(localized: "New Tab"), #selector(AppDelegate.newTab(_:)), "t"))
        menu.addItem(item(String(localized: "New Folder"), #selector(B.newFolder(_:)), "n", [.command, .shift]))
        menu.addItem(item(String(localized: "New Text Document"), #selector(B.newTextDocument(_:)), "n", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Open"), #selector(B.openSelection(_:)), functionKey(NSDownArrowFunctionKey)))
        menu.addItem(item(String(localized: "Open in New Tab"), #selector(B.openInNewTab(_:))))
        menu.addItem(item(String(localized: "Open in New Window"), #selector(B.openInNewWindow(_:))))
        menu.addItem(item(String(localized: "Close Tab"), #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Properties"), #selector(B.showProperties(_:)), "i"))
        menu.addItem(item(String(localized: "Compress to ZIP File"), #selector(B.compressToZip(_:))))
        menu.addItem(item(String(localized: "Extract All…"), #selector(B.extractAll(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Pin to Quick Access"), #selector(B.togglePin(_:)), "t", [.command, .control]))
        menu.addItem(item(String(localized: "Open in Terminal"), #selector(B.openInTerminal(_:))))
        menu.addItem(item(String(localized: "Show in Finder"), #selector(B.showInFinder(_:)), "r", [.command, .option]))
        menu.addItem(item(String(localized: "Eject"), #selector(B.ejectVolume(_:)), "e"))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Delete"), #selector(B.moveToTrash(_:)), "\u{8}"))
        menu.addItem(item(String(localized: "Delete Permanently…"), #selector(B.deletePermanently(_:)), "\u{8}", [.command, .option]))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(String(localized: "Undo"), Selector(("undo:")), "z"))
        menu.addItem(item(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Cut"), #selector(B.cut(_:)), "x"))
        menu.addItem(item(String(localized: "Copy"), #selector(B.copy(_:)), "c"))
        menu.addItem(item(String(localized: "Paste"), #selector(B.paste(_:)), "v"))
        menu.addItem(item(String(localized: "Copy as Path"), #selector(B.copyAsPath(_:)), "c", [.command, .option]))
        menu.addItem(item(String(localized: "Duplicate"), #selector(B.duplicate(_:)), "d"))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Rename"), #selector(B.renameSelection(_:)), functionKey(NSF2FunctionKey), []))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Select All"), #selector(NSResponder.selectAll(_:)), "a"))
        menu.addItem(item(String(localized: "Select None"), #selector(B.selectNone(_:)), "a", [.command, .option]))
        menu.addItem(item(String(localized: "Invert Selection"), #selector(B.invertSelection(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Search"), #selector(B.focusSearch(_:)), "f"))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, mode) in ViewMode.allCases.enumerated() {
            menu.addItem(item(mode.title, #selector(B.setViewModeFromMenu(_:)), "\(mode.shortcutNumber)", [.control, .shift], tag: index))
        }
        menu.addItem(.separator())
        let sort = NSMenu()
        for (index, key) in SortKey.allCases.enumerated() {
            sort.addItem(item(key.title, #selector(B.sortByFromMenu(_:)), tag: index))
        }
        sort.addItem(.separator())
        sort.addItem(item(String(localized: "Ascending"), #selector(B.setSortAscending(_:))))
        sort.addItem(item(String(localized: "Descending"), #selector(B.setSortDescending(_:))))
        menu.addItem(submenu(String(localized: "Sort By"), sort))
        let group = NSMenu()
        for (index, key) in GroupKey.allCases.enumerated() {
            group.addItem(item(key.title, #selector(B.groupByFromMenu(_:)), tag: index))
            if key == .none { group.addItem(.separator()) }
        }
        menu.addItem(submenu(String(localized: "Group By"), group))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Navigation Pane"), #selector(B.toggleNavigationPane(_:)), "s", [.command, .control]))
        menu.addItem(item(String(localized: "Preview Pane"), #selector(B.togglePreviewPane(_:)), "p", [.command, .option]))
        menu.addItem(item(String(localized: "File Name Extensions"), #selector(B.toggleFileExtensions(_:))))
        menu.addItem(item(String(localized: "Hidden Items"), #selector(B.toggleHiddenItems(_:)), ".", [.command, .shift]))
        menu.addItem(item(String(localized: "Item Check Boxes"), #selector(B.toggleOption(_:)), object: FolderOption.itemCheckBoxes.rawValue))
        menu.addItem(item(String(localized: "Compact View"), #selector(B.toggleOption(_:)), object: FolderOption.compactView.rawValue))
        menu.addItem(item(String(localized: "Status Bar"), #selector(B.toggleOption(_:)), "/", [.command], object: FolderOption.showStatusBar.rawValue))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quick Look"), #selector(B.quickLook(_:)), "y"))
        menu.addItem(item(String(localized: "Refresh"), #selector(B.refresh(_:)), "r"))
        menu.addItem(.separator())
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(String(localized: "Back"), #selector(B.goBackAction(_:)), "["))
        menu.addItem(item(String(localized: "Forward"), #selector(B.goForwardAction(_:)), "]"))
        menu.addItem(item(String(localized: "Up"), #selector(B.goUpAction(_:)), functionKey(NSUpArrowFunctionKey)))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "This Mac"), #selector(B.goToThisMac(_:)), "c", [.command, .shift]))
        let fm = FileManager.default
        menu.addItem(item(String(localized: "Home"), #selector(B.goToFolder(_:)), "h", [.command, .shift], object: fm.homeDirectoryForCurrentUser.normalizedFolder))
        let places: [(String, FileManager.SearchPathDirectory, FileManager.SearchPathDomainMask, String, NSEvent.ModifierFlags)] = [
            (String(localized: "Desktop"), .desktopDirectory, .userDomainMask, "d", [.command, .shift]),
            (String(localized: "Documents"), .documentDirectory, .userDomainMask, "o", [.command, .shift]),
            (String(localized: "Downloads"), .downloadsDirectory, .userDomainMask, "l", [.command, .option]),
            (String(localized: "Applications"), .applicationDirectory, .localDomainMask, "a", [.command, .shift]),
            (String(localized: "Utilities"), .applicationDirectory, .localDomainMask, "u", [.command, .shift]),
        ]
        for (title, directory, domain, key, modifiers) in places {
            guard var url = fm.urls(for: directory, in: domain).first else { continue }
            if key == "u" { url = url.appendingPathComponent("Utilities", isDirectory: true) }
            menu.addItem(item(title, #selector(B.goToFolder(_:)), key, modifiers, object: url.normalizedFolder))
        }
        let iCloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fm.fileExists(atPath: iCloud.path) {
            menu.addItem(item(String(localized: "iCloud Drive"), #selector(B.goToFolder(_:)), "i", [.command, .shift], object: iCloud.normalizedFolder))
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Go to Folder…"), #selector(B.focusAddressBar(_:)), "g", [.command, .shift]))
        menu.addItem(item(String(localized: "Connect to Server…"), #selector(B.connectToServer(_:)), "k"))
        menu.addItem(item(String(localized: "Map Network Drive…"), #selector(B.mapNetworkDrive(_:))))
        menu.addItem(item(String(localized: "Edit Address"), #selector(B.focusAddressBar(_:)), "l"))
        menu.addItem(.separator())
        let recent = NSMenu()
        recent.delegate = RecentFilesMenu.shared
        menu.addItem(submenu(String(localized: "Recent Files"), recent))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(String(localized: "Arbor Keyboard Shortcuts"), #selector(AppDelegate.showHelp(_:)), "?"))
        return menu
    }
}

/// Go › Recent Files: files opened from Arbor ("Show recently used files" in Folder Options).
final class RecentFilesMenu: NSObject, NSMenuDelegate {
    static let shared = RecentFilesMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let files = Preferences.shared[.showRecentFiles] ? RecentItems.shared.recentFiles() : []
        if files.isEmpty {
            let empty = NSMenuItem(title: Preferences.shared[.showRecentFiles] ? "No Recent Files" : "Recent Files Are Turned Off", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for file in files {
            let item = NSMenuItem(title: file.lastPathComponent, action: #selector(openFile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = file
            item.toolTip = file.path
            item.image = IconCache.icon(for: file).menuSized
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: String(localized: "Clear Menu"), action: #selector(clear), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc private func openFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
        RecentItems.shared.recordFileOpen(url)
    }

    @objc private func clear() { RecentItems.shared.clear() }
}
