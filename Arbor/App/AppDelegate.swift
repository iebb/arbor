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
        Updater.shared.start()
        SandboxAccess.restore()
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
                VolumeService.invalidateCache()
                NotificationCenter.default.post(name: .arborVolumesChanged, object: nil)
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            FileClipboard.shared.checkForExternalChanges()
        }

        didFinishLaunching = true
        #if DEBUG
        if let idx = CommandLine.arguments.firstIndex(of: "--capture-screenshots"),
           CommandLine.arguments.count > idx + 2 {
            let outDir = URL(fileURLWithPath: CommandLine.arguments[idx + 1], isDirectory: true)
            let demoDir = URL(fileURLWithPath: CommandLine.arguments[idx + 2], isDirectory: true)
            let suffix = CommandLine.arguments.count > idx + 3 && !CommandLine.arguments[idx + 3].hasPrefix("-")
                ? CommandLine.arguments[idx + 3]
                : "en"
            captureScreenshots(outDir: outDir, demoDir: demoDir, suffix: suffix)
            return
        }
        #endif
        if SandboxAccess.needsAccess { SandboxAccess.requestAccess() }
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

    /// App Store build: Arbor › Grant Disk Access…
    @objc func grantDiskAccess(_ sender: Any?) {
        SandboxAccess.requestAccess()
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

    #if DEBUG
    /// Renders clean 2x Retina marketing screenshots of all windows (with personal info redacted).
    private func captureScreenshots(outDir: URL, demoDir: URL, suffix: String) {
        DemoRedactor.enabled = true
        DemoRedactor.demoRoot = demoDir
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let photosDir = demoDir.appendingPathComponent("Photos", isDirectory: true)
        let heroPhoto = demoDir.appendingPathComponent("Hero Banner.jpg")
        let firstGalleryPhoto = ((try? FileManager.default.contentsOfDirectory(at: photosDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first

        let controller = openWindow(.folder(demoDir))
        guard let window = controller.window else { NSApp.terminate(nil); return }
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: 1180, height: 740))
        let browser = controller.browser

        func snap(_ name: String, after delay: TimeInterval, overlay: (() -> NSWindow?)? = nil, setup: @escaping () -> Void, next: @escaping () -> Void) {
            setup()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                window.layoutIfNeeded()
                let modal = overlay?()
                modal?.layoutIfNeeded()
                self.saveWindowPNG(window, overlay: modal, to: outDir.appendingPathComponent(name))
                modal?.orderOut(nil)
                next()
            }
        }

        // 1. Light mode: Details view + Details pane with a photo selected
        snap("details-\(suffix).png", after: 1.5, setup: {
            NSApp.appearance = NSAppearance(named: .aqua)
            window.appearance = NSAppearance(named: .aqua)
            browser.setViewMode(.details)
            browser.setGroupBy(.none)
            browser.setSidePane(.details)
            browser.setPendingSelection([heroPhoto])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                browser.presenter?.select([heroPhoto], scroll: true)
            }
        }) {
            // 2. Light mode: Collapsible Groups (Group by Type)
            snap("grouped-\(suffix).png", after: 0.9, setup: {
                browser.setSidePane(.none)
                browser.setGroupBy(.type)
                browser.presenter?.select([heroPhoto], scroll: false)
            }) {
                // 3. Light mode: Folder Options (Settings) window opened inside main window
                let settings = SettingsWindowController()
                snap("settings-\(suffix).png", after: 0.9, overlay: { settings.window }, setup: {
                    window.setContentSize(NSSize(width: 1220, height: 820))
                    browser.setGroupBy(.none)
                    browser.setSidePane(.none)
                    browser.presenter?.select([heroPhoto], scroll: false)
                    settings.window?.appearance = NSAppearance(named: .aqua)
                    settings.selectTab(at: 1) // View tab (Explorer Advanced settings)
                    settings.present()
                }) {
                    // 4. Light mode: Properties window opened inside main window
                    let props = PropertiesWindowController.show(for: [heroPhoto])
                    snap("properties-\(suffix).png", after: 0.9, overlay: { props.window }, setup: {
                        window.setContentSize(NSSize(width: 1180, height: 740))
                        props.window?.appearance = NSAppearance(named: .aqua)
                    }) {
                        // 5. Dark mode: Large Icons with Bing Daily Backgrounds + Details pane
                        snap("photos-dark-\(suffix).png", after: 2.0, setup: {
                            NSApp.appearance = NSAppearance(named: .darkAqua)
                            window.appearance = NSAppearance(named: .darkAqua)
                            browser.navigate(to: .folder(photosDir))
                            browser.setViewMode(.largeIcons)
                            browser.setGroupBy(.none)
                            browser.setSidePane(.details)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                                if let first = firstGalleryPhoto { browser.presenter?.select([first], scroll: false) }
                            }
                        }) {
                            // 6. Light mode: This Mac with redacted user/drive names & rounded bars
                            snap("thismac-\(suffix).png", after: 0.9, setup: {
                                NSApp.appearance = NSAppearance(named: .aqua)
                                window.appearance = NSAppearance(named: .aqua)
                                browser.setSidePane(.none)
                                browser.navigate(to: .thisMac)
                            }) {
                                DemoRedactor.enabled = false
                                NSApp.appearance = nil
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            }
        }
    }

    private func drawFramedWindow(_ window: NSWindow, in winRect: NSRect, isDark: Bool, shadowRadius: CGFloat) {
        guard let contentView = window.contentView else { return }
        let titleHeight: CGFloat = 28
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        var contentRep: NSBitmapImageRep?
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) {
                contentView.cacheDisplay(in: contentView.bounds, to: rep)
                contentRep = rep
            }
        }
        guard let contentRep else { return }

        let winPath = NSBezierPath(roundedRect: winRect, xRadius: 11, yRadius: 11)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.55 : 0.28)
        shadow.shadowBlurRadius = shadowRadius
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        winPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        winPath.addClip()

        NSColor.windowBackgroundColor.setFill()
        winRect.fill()

        let titleRect = NSRect(x: winRect.minX, y: winRect.maxY - titleHeight, width: winRect.width, height: titleHeight)
        (isDark ? NSColor(white: 0.20, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
        titleRect.fill()

        let dots: [(CGFloat, NSColor)] = [
            (14, NSColor(red: 1.0, green: 0.37, blue: 0.34, alpha: 1)),
            (34, NSColor(red: 1.0, green: 0.74, blue: 0.18, alpha: 1)),
            (54, NSColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1)),
        ]
        for (dx, color) in dots {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: titleRect.minX + dx, y: titleRect.midY - 6, width: 12, height: 12)).fill()
        }

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let titleStr = window.title as NSString
        let tSize = titleStr.size(withAttributes: titleAttrs)
        titleStr.draw(at: NSPoint(x: titleRect.midX - tSize.width / 2, y: titleRect.midY - tSize.height / 2), withAttributes: titleAttrs)

        NSColor.separatorColor.setFill()
        NSRect(x: titleRect.minX, y: titleRect.minY, width: titleRect.width, height: 1).fill()

        let contentRect = NSRect(x: winRect.minX, y: winRect.minY, width: winRect.width, height: winRect.height - titleHeight)
        contentRep.draw(in: contentRect)
        NSGraphicsContext.restoreGraphicsState()

        (isDark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.14)).setStroke()
        winPath.lineWidth = 0.75
        winPath.stroke()
    }

    private func saveWindowPNG(_ window: NSWindow, overlay: NSWindow?, to url: URL) {
        guard let contentView = window.contentView else { return }
        let titleHeight: CGFloat = 28
        let contentSize = contentView.bounds.size
        let winSize = NSSize(width: contentSize.width, height: contentSize.height + titleHeight)
        let pad: CGFloat = 28
        let canvasSize = NSSize(width: winSize.width + pad * 2, height: winSize.height + pad * 2)
        let scale: CGFloat = 2

        window.makeKeyAndOrderFront(nil)

        guard let outRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvasSize.width * scale),
            pixelsHigh: Int(canvasSize.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        outRep.size = canvasSize

        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            guard let ctx = NSGraphicsContext(bitmapImageRep: outRep) else { return }
            NSGraphicsContext.current = ctx
            let isDark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let winRect = NSRect(x: pad, y: pad, width: winSize.width, height: winSize.height)
            drawFramedWindow(window, in: winRect, isDark: isDark, shadowRadius: 20)

            if let overlay, let overlayContent = overlay.contentView {
                let oSize = NSSize(width: overlayContent.bounds.width, height: overlayContent.bounds.height + titleHeight)
                // Place the dialog inside the main window, slightly right of center so the sidebar and file list remain visible.
                let ox = winRect.minX + (winRect.width - oSize.width) * 0.62
                let oy = winRect.minY + (winRect.height - titleHeight - oSize.height) * 0.5
                let oRect = NSRect(origin: NSPoint(x: ox, y: oy), size: oSize)
                drawFramedWindow(overlay, in: oRect, isDark: isDark, shadowRadius: 26)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if let png = outRep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
    #endif
}
