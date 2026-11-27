import AppKit

/// The menu bar. Mac shortcuts are listed in menus; Explorer's (F2, Alt+←, Backspace…) also work —
/// see `BrowserViewController.handleKeyDown`.
enum MainMenu {
    private typealias B = BrowserViewController

    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("Arbor", appMenu()))
        main.addItem(submenu("File", fileMenu()))
        main.addItem(submenu("Edit", editMenu()))
        main.addItem(submenu("View", viewMenu()))
        main.addItem(submenu("Go", goMenu()))
        let window = windowMenu()
        main.addItem(submenu("Window", window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenu("Help", help))
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
        menu.addItem(item("About Arbor", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        let services = NSMenu()
        menu.addItem(submenu("Services", services))
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(item("Hide Arbor", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Arbor", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), "n"))
        menu.addItem(item("New Tab", #selector(AppDelegate.newTab(_:)), "t"))
        menu.addItem(item("New Folder", #selector(B.newFolder(_:)), "n", [.command, .shift]))
        menu.addItem(item("New Text Document", #selector(B.newTextDocument(_:)), "n", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Open", #selector(B.openSelection(_:)), functionKey(NSDownArrowFunctionKey)))
        menu.addItem(item("Open in New Tab", #selector(B.openInNewTab(_:))))
        menu.addItem(item("Open in New Window", #selector(B.openInNewWindow(_:))))
        menu.addItem(item("Close Tab", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(item("Properties", #selector(B.showProperties(_:)), "i"))
        menu.addItem(item("Compress to ZIP File", #selector(B.compressToZip(_:))))
        menu.addItem(item("Extract All…", #selector(B.extractAll(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Pin to Quick Access", #selector(B.togglePin(_:)), "t", [.command, .control]))
        menu.addItem(item("Open in Terminal", #selector(B.openInTerminal(_:))))
        menu.addItem(item("Show in Finder", #selector(B.showInFinder(_:)), "r", [.command, .option]))
        menu.addItem(item("Eject", #selector(B.ejectVolume(_:)), "e"))
        menu.addItem(.separator())
        menu.addItem(item("Delete", #selector(B.moveToTrash(_:)), "\u{8}"))
        menu.addItem(item("Delete Permanently…", #selector(B.deletePermanently(_:)), "\u{8}", [.command, .option]))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(B.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(B.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(B.paste(_:)), "v"))
        menu.addItem(item("Copy as Path", #selector(B.copyAsPath(_:)), "c", [.command, .option]))
        menu.addItem(item("Duplicate", #selector(B.duplicate(_:)), "d"))
        menu.addItem(.separator())
        menu.addItem(item("Rename", #selector(B.renameSelection(_:)), functionKey(NSF2FunctionKey), []))
        menu.addItem(.separator())
        menu.addItem(item("Select All", #selector(NSResponder.selectAll(_:)), "a"))
        menu.addItem(item("Select None", #selector(B.selectNone(_:)), "a", [.command, .option]))
        menu.addItem(item("Invert Selection", #selector(B.invertSelection(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Search", #selector(B.focusSearch(_:)), "f"))
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
        sort.addItem(item("Ascending", #selector(B.setSortAscending(_:))))
        sort.addItem(item("Descending", #selector(B.setSortDescending(_:))))
        menu.addItem(submenu("Sort By", sort))
        menu.addItem(.separator())
        menu.addItem(item("Navigation Pane", #selector(B.toggleNavigationPane(_:)), "s", [.command, .control]))
        menu.addItem(item("Preview Pane", #selector(B.togglePreviewPane(_:)), "p", [.command, .option]))
        menu.addItem(item("File Name Extensions", #selector(B.toggleFileExtensions(_:))))
        menu.addItem(item("Hidden Items", #selector(B.toggleHiddenItems(_:)), ".", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Quick Look", #selector(B.quickLook(_:)), "y"))
        menu.addItem(item("Refresh", #selector(B.refresh(_:)), "r"))
        menu.addItem(.separator())
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Back", #selector(B.goBackAction(_:)), "["))
        menu.addItem(item("Forward", #selector(B.goForwardAction(_:)), "]"))
        menu.addItem(item("Up", #selector(B.goUpAction(_:)), functionKey(NSUpArrowFunctionKey)))
        menu.addItem(.separator())
        menu.addItem(item("This Mac", #selector(B.goToThisMac(_:)), "c", [.command, .shift]))
        let fm = FileManager.default
        menu.addItem(item("Home", #selector(B.goToFolder(_:)), "h", [.command, .shift], object: fm.homeDirectoryForCurrentUser.normalizedFolder))
        let places: [(String, FileManager.SearchPathDirectory, FileManager.SearchPathDomainMask, String, NSEvent.ModifierFlags)] = [
            ("Desktop", .desktopDirectory, .userDomainMask, "d", [.command, .shift]),
            ("Documents", .documentDirectory, .userDomainMask, "o", [.command, .shift]),
            ("Downloads", .downloadsDirectory, .userDomainMask, "l", [.command, .option]),
            ("Applications", .applicationDirectory, .localDomainMask, "a", [.command, .shift]),
            ("Utilities", .applicationDirectory, .localDomainMask, "u", [.command, .shift]),
        ]
        for (title, directory, domain, key, modifiers) in places {
            guard var url = fm.urls(for: directory, in: domain).first else { continue }
            if title == "Utilities" { url = url.appendingPathComponent("Utilities", isDirectory: true) }
            menu.addItem(item(title, #selector(B.goToFolder(_:)), key, modifiers, object: url.normalizedFolder))
        }
        let iCloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fm.fileExists(atPath: iCloud.path) {
            menu.addItem(item("iCloud Drive", #selector(B.goToFolder(_:)), "i", [.command, .shift], object: iCloud.normalizedFolder))
        }
        menu.addItem(.separator())
        menu.addItem(item("Go to Folder…", #selector(B.focusAddressBar(_:)), "g", [.command, .shift]))
        menu.addItem(item("Edit Address", #selector(B.focusAddressBar(_:)), "l"))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Arbor Keyboard Shortcuts", #selector(AppDelegate.showHelp(_:)), "?"))
        return menu
    }
}
