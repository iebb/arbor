import AppKit

/// A browser window. Each macOS tab is its own window in the same tab group, like Explorer tabs.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    static let tabbingIdentifier = "ArborBrowser"
    let browser: BrowserViewController

    init(location: Location, select: [URL] = []) {
        browser = BrowserViewController(location: location, select: select)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 1180, height: 720))
        window.minSize = NSSize(width: 640, height: 400)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("ArborBrowserWindow")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The "+" button in the tab bar.
    override func newWindowForTab(_ sender: Any?) {
        AppDelegate.shared.openTab(Preferences.shared.startLocation.location, from: window)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        FileOperationService.shared.undoManager
    }

    func windowDidBecomeKey(_ notification: Notification) {
        FileClipboard.shared.checkForExternalChanges()
        browser.updateCommandStates()
    }

    func windowWillClose(_ notification: Notification) {
        AppDelegate.shared.windowControllerDidClose(self)
    }
}
