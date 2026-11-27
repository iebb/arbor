import AppKit
import UniformTypeIdentifiers

/// Arbor's "Folder Options".
final class SettingsWindowController: NSWindowController {
    private let startPopup = NSPopUpButton()
    private let backspacePopup = NSPopUpButton()
    private let hiddenBox = NSButton(checkboxWithTitle: "Show hidden files, folders, and drives", target: nil, action: nil)
    private let extensionsBox = NSButton(checkboxWithTitle: "Hide extensions for known file types", target: nil, action: nil)
    private let expandBox = NSButton(checkboxWithTitle: "Expand to open folder", target: nil, action: nil)
    private let defaultStatus = NSTextField.label("", size: 11, color: .secondaryLabelColor)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Folder Options"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        window.center()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        for location in StartLocation.allCases { startPopup.addItem(withTitle: location.title) }
        startPopup.target = self
        startPopup.action = #selector(startChanged)

        backspacePopup.addItems(withTitles: ["Goes back (like Explorer)", "Moves selection to the Trash"])
        backspacePopup.target = self
        backspacePopup.action = #selector(backspaceChanged)

        for box in [hiddenBox, extensionsBox, expandBox] {
            box.target = self
            box.action = #selector(checkboxChanged(_:))
        }

        let resetButton = NSButton(title: "Reset Folders", target: self, action: #selector(resetFolders))
        let applyButton = NSButton(title: "Apply to Folders", target: self, action: #selector(applyToFolders))
        let folderViews = NSStackView(views: [applyButton, resetButton])

        let makeDefault = NSButton(title: "Use Arbor to Open Folders", target: self, action: #selector(makeDefault))
        let restoreFinder = NSButton(title: "Restore Finder", target: self, action: #selector(restoreFinder))
        let defaultButtons = NSStackView(views: [makeDefault, restoreFinder])

        let grid = NSGridView(views: [
            [caption("Open Arbor to:"), startPopup],
            [caption("Backspace key:"), backspacePopup],
            [caption("Navigation pane:"), expandBox],
            [caption("Advanced:"), hiddenBox],
            [NSGridCell.emptyContentView, extensionsBox],
            [caption("Folder views:"), folderViews],
            [NSGridCell.emptyContentView, note("Apply to Folders makes the current tab's layout the default. Reset Folders forgets every folder's remembered layout.")],
            [caption("Default browser:"), defaultButtons],
            [NSGridCell.emptyContentView, defaultStatus],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            content.widthAnchor.constraint(equalToConstant: 560),
        ])
        window?.contentView = content
    }

    private func caption(_ text: String) -> NSTextField {
        NSTextField.label(text)
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 360
        return label
    }

    private func refresh() {
        let prefs = Preferences.shared
        startPopup.selectItem(at: StartLocation.allCases.firstIndex(of: prefs.startLocation) ?? 0)
        backspacePopup.selectItem(at: prefs.backspaceGoesBack ? 0 : 1)
        hiddenBox.state = prefs.showHidden ? .on : .off
        extensionsBox.state = prefs.showExtensions ? .off : .on
        expandBox.state = prefs.expandToOpenFolder ? .on : .off
        let handler = NSWorkspace.shared.urlForApplication(toOpen: .folder)
        let name = handler.map { FileManager.default.displayName(atPath: $0.path) } ?? "Finder"
        defaultStatus.stringValue = "Folders opened by other apps currently open in \(name)."
    }

    @objc private func startChanged() {
        Preferences.shared.startLocation = StartLocation.allCases[startPopup.indexOfSelectedItem]
    }

    @objc private func backspaceChanged() {
        Preferences.shared.backspaceGoesBack = backspacePopup.indexOfSelectedItem == 0
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender {
        case hiddenBox: Preferences.shared.showHidden = on
        case extensionsBox: Preferences.shared.showExtensions = !on
        case expandBox: Preferences.shared.expandToOpenFolder = on
        default: break
        }
    }

    @objc private func resetFolders() {
        FolderViewStore.shared.reset()
        NotificationCenter.default.post(name: .arborPreferencesChanged, object: nil)
    }

    @objc private func applyToFolders() {
        guard let browser = AppDelegate.shared.frontmostBrowser else { return }
        FolderViewStore.shared.applyToAllFolders(browser.viewSettings)
        NotificationCenter.default.post(name: .arborPreferencesChanged, object: nil)
    }

    @objc private func makeDefault() {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .folder) { [weak self] error in
            DispatchQueue.main.async {
                if let error { FileOperationService.shared.present(error, window: self?.window) }
                self?.refresh()
            }
        }
    }

    @objc private func restoreFinder() {
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        NSWorkspace.shared.setDefaultApplication(at: finder, toOpen: .folder) { [weak self] error in
            DispatchQueue.main.async {
                if let error { FileOperationService.shared.present(error, window: self?.window) }
                self?.refresh()
            }
        }
    }
}
