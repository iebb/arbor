import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let instance = AppDelegate()
    static var shared: AppDelegate { instance }

    private var controllers: [BrowserWindowController] = []
    private var settingsController: SettingsWindowController?
    private var keyMonitor: Any?
    private var pendingOpenURLs: [URL] = []
    private var didFinishLaunching = false

    static func main() {
        let app = NSApplication.shared
        app.delegate = instance
        app.setActivationPolicy(.regular)
        app.run()
    }

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installKeyMonitor()
        GlobalHotKey.shared.onPress = { [weak self] in
            NSApp.activate()
            self?.openWindow(Preferences.shared.startLocation.location)
        }
        GlobalHotKey.shared.apply(Preferences.shared.hotKey)
        NotificationCenter.default.addObserver(forName: .arborPreferencesChanged, object: nil, queue: .main) { _ in
            GlobalHotKey.shared.apply(Preferences.shared.hotKey)
        }
        NetworkLocations.reconnectSaved()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                NotificationCenter.default.post(name: .arborVolumesChanged, object: nil)
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            FileClipboard.shared.checkForExternalChanges()
        }

        didFinishLaunching = true
        if pendingOpenURLs.isEmpty {
            if let start = startLocationFromArguments() {
                openWindow(start)
            } else if !restoreSavedWindows() {
                openWindow(Preferences.shared.startLocation.location)
            }
        } else {
            open(pendingOpenURLs)
            pendingOpenURLs = []
        }
        NSApp.activate()
    }

    /// `Arbor.app/Contents/MacOS/Arbor /some/folder` opens that folder (handy for scripts and testing).
    private func startLocationFromArguments() -> Location? {
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        guard let path = arguments.first else { return nil }
        if case .location(let location) = PathResolver.resolve(path, relativeTo: nil) { return location }
        return nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow(Preferences.shared.startLocation.location) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        saveWindows()
    }

    // MARK: Restore previous folder windows

    private static let savedWindowsKey = "SavedWindows"

    /// Each window as its tabs' locations, in tab order ("This Mac" or a folder path).
    private func saveWindows() {
        var seen = Set<ObjectIdentifier>()
        var saved: [[String]] = []
        for window in NSApp.orderedWindows where window.windowController is BrowserWindowController {
            let group = window.tabbedWindows ?? [window]
            guard !group.contains(where: { seen.contains(ObjectIdentifier($0)) }) else { continue }
            group.forEach { seen.insert(ObjectIdentifier($0)) }
            let tabs: [String] = group.compactMap { tab in
                guard let browser = (tab.windowController as? BrowserWindowController)?.browser else { return nil }
                switch browser.location {
                case .thisMac: return "thisMac"
                case .folder(let url): return url.pathKey
                case .search(let root, _): return root.pathKey
                }
            }
            if !tabs.isEmpty { saved.append(tabs) }
        }
        UserDefaults.standard.set(saved, forKey: Self.savedWindowsKey)
    }

    /// "Restore previous folder windows at launch". Returns false when there was nothing to restore.
    private func restoreSavedWindows() -> Bool {
        guard Preferences.shared[.restoreWindowsAtLaunch],
              let saved = UserDefaults.standard.array(forKey: Self.savedWindowsKey) as? [[String]] else { return false }
        var restored = false
        for tabs in saved.reversed() {
            let locations: [Location] = tabs.compactMap { entry in
                if entry == "thisMac" { return .thisMac }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: entry, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
                return .folder(URL(fileURLWithPath: entry, isDirectory: true))
            }
            guard let first = locations.first else { continue }
            let window = openWindow(first).window
            for location in locations.dropFirst() { openTab(location, from: window) }
            restored = true
        }
        return restored
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Folders opened from other apps (or dropped on the Dock icon) open in a new tab.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard didFinishLaunching else {
            pendingOpenURLs += urls
            return
        }
        open(urls)
    }

    private func open(_ urls: [URL]) {
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
            if isDirectory.boolValue && !isPackage {
                openTab(.folder(url), from: NSApp.keyWindow)
            } else {
                openTab(.folder(url.parentFolder), select: [url], from: NSApp.keyWindow)
            }
        }
    }

    // MARK: Windows and tabs

    var frontmostBrowser: BrowserViewController? {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        return (window?.windowController as? BrowserWindowController)?.browser
            ?? controllers.last?.browser
    }

    @discardableResult
    func openWindow(_ location: Location, select: [URL] = []) -> BrowserWindowController {
        let controller = BrowserWindowController(location: location, select: select)
        controllers.append(controller)
        controller.window?.tabbingMode = .disallowed
        controller.showWindow(nil)
        controller.window?.tabbingMode = .preferred
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    func openTab(_ location: Location, select: [URL] = [], from window: NSWindow?) {
        guard let host = window ?? NSApp.keyWindow, host.windowController is BrowserWindowController else {
            openWindow(location, select: select)
            return
        }
        let controller = BrowserWindowController(location: location, select: select)
        controllers.append(controller)
        if let newWindow = controller.window {
            host.addTabbedWindow(newWindow, ordered: .above)
            newWindow.makeKeyAndOrderFront(nil)
        }
    }

    func windowControllerDidClose(_ controller: BrowserWindowController) {
        controllers.removeAll { $0 === controller }
    }

    // MARK: Menu actions

    /// ⌘N: a new window at the same folder, like Explorer's Ctrl+N.
    @objc func newWindow(_ sender: Any?) {
        openWindow(frontmostBrowser?.location ?? Preferences.shared.startLocation.location)
    }

    /// ⌘T: a new tab at the start location.
    @objc func newTab(_ sender: Any?) {
        openTab(Preferences.shared.startLocation.location, from: NSApp.keyWindow)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsController == nil { settingsController = SettingsWindowController() }
        settingsController?.present()
    }

    @objc func showHelp(_ sender: Any?) {
        if let url = URL(string: "https://github.com/iebb/arbor#keyboard-shortcuts") { NSWorkspace.shared.open(url) }
    }

    // MARK: Explorer keys

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let controller = event.window?.windowController as? BrowserWindowController,
                  event.window?.attachedSheet == nil else { return event }
            return controller.browser.handleKeyDown(event) ? nil : event
        }
    }
}
