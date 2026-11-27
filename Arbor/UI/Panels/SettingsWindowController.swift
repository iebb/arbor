import AppKit
import UniformTypeIdentifiers

/// Explorer's "Folder Options" dialog: General, View and Search tabs with OK / Cancel / Apply.
///
/// Changes are made to a draft and only take effect on Apply or OK, like Windows. "Apply to Folders",
/// "Reset Folders" and "Clear" act straight away (they do in Explorer too).
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var draft: [FolderOption: Bool] = [:]
    private var draftStart: StartLocation = .home
    private var draftHotKey: HotKeyChoice = .off
    private var draftLoginItem = false
    private let hotKeyPopup = NSPopUpButton()
    private let loginBox = NSButton(checkboxWithTitle: String(localized: "Open Arbor at login"), target: nil, action: nil)
    private var refreshers: [() -> Void] = []
    private let startPopup = NSPopUpButton()
    private let applyButton = NSButton(title: String(localized: "Apply"), target: nil, action: nil)
    private let tabView = NSTabView()
    private let defaultStatus = NSTextField.label("", size: 11, color: .secondaryLabelColor)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Folder Options")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows the dialog with the current settings (discarding any edits left from last time).
    func present() {
        loadDraft()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func loadDraft() {
        draft = Dictionary(uniqueKeysWithValues: FolderOption.allCases.map { ($0, Preferences.shared[$0]) })
        draftStart = Preferences.shared.startLocation
        draftHotKey = Preferences.shared.hotKey
        draftLoginItem = LoginItem.isEnabled
        refreshAll()
    }

    private func value(_ option: FolderOption) -> Bool { draft[option] ?? Preferences.shared[option] }

    private func set(_ option: FolderOption, _ value: Bool) {
        draft[option] = value
        refreshAll()
    }

    private var isDirty: Bool {
        draftStart != Preferences.shared.startLocation || draftHotKey != Preferences.shared.hotKey
            || draftLoginItem != LoginItem.isEnabled || draft.contains { Preferences.shared[$0.key] != $0.value }
    }

    private func refreshAll() {
        refreshers.forEach { $0() }
        if let index = StartLocation.available.firstIndex(of: draftStart) { startPopup.selectItem(at: index) }
        hotKeyPopup.selectItem(at: HotKeyChoice.allCases.firstIndex(of: draftHotKey) ?? 0)
        loginBox.state = draftLoginItem ? .on : .off
        applyButton.isEnabled = isDirty
        let handler = NSWorkspace.shared.urlForApplication(toOpen: .folder)
        let name = handler.map { FileManager.default.displayName(atPath: $0.path) } ?? "Finder"
        defaultStatus.stringValue = String(localized: "Folders opened from other apps currently open in \(name).")
    }

    // MARK: Layout

    private func build() {
        tabView.translatesAutoresizingMaskIntoConstraints = false
        for (title, content) in [(String(localized: "General"), generalTab()), (String(localized: "View"), viewTab()), (String(localized: "Search"), searchTab())] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            item.view = content
            tabView.addTabViewItem(item)
        }

        let ok = NSButton(title: String(localized: "OK"), target: self, action: #selector(okPressed))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        applyButton.target = self
        applyButton.action = #selector(applyPressed)
        for button in [ok, cancel, applyButton] {
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        }
        let buttons = NSStackView(views: [ok, cancel, applyButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(tabView)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            buttons.topAnchor.constraint(equalTo: tabView.bottomAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            content.widthAnchor.constraint(equalToConstant: 480),
            content.heightAnchor.constraint(equalToConstant: 740),
        ])
        window?.contentView = content
    }

    /// A tab page: rows top to bottom, with "Restore Defaults" at the bottom right.
    private func page(_ rows: [NSView], restore: Selector) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let restoreButton = NSButton(title: String(localized: "Restore Defaults"), target: self, action: restore)
        restoreButton.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        view.addSubview(restoreButton)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            restoreButton.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 12),
            restoreButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            restoreButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
        ])
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return view
    }

    /// A titled group box with a large icon on the left, like the boxes in Explorer's dialog.
    private func group(_ title: String, symbol: String?, _ rows: [NSView]) -> NSView {
        let box = NSBox()
        box.title = title
        box.titleFont = .systemFont(ofSize: 12)
        box.translatesAutoresizingMaskIntoConstraints = false
        let inner = NSStackView(views: rows)
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 7
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.setClippingResistancePriority(.required, for: .vertical)
        inner.setHuggingPriority(.defaultLow, for: .vertical)
        let container = box.contentView ?? NSView()
        container.addSubview(inner)
        var leading = inner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10)
        if let symbol {
            let icon = NSImageView(image: NSImage.symbol(symbol, size: 26) ?? NSImage())
            icon.contentTintColor = .controlAccentColor
            icon.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
                icon.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
                icon.widthAnchor.constraint(equalToConstant: 34),
            ])
            leading = inner.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10)
        }
        NSLayoutConstraint.activate([
            leading,
            inner.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            inner.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -10),
            inner.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        return box
    }

    private func check(_ title: String, _ option: FolderOption, inverted: Bool = false, enabledWhen: (() -> Bool)? = nil, confirm: ((Bool) -> Bool)? = nil) -> NSButton {
        let button = ClosureButton(checkboxWithTitle: title)
        button.handler = { [weak self, weak button] in
            guard let self, let button else { return }
            let checked = button.state == .on
            if let confirm, !confirm(checked) {
                self.refreshAll()
                return
            }
            self.set(option, checked != inverted)
        }
        refreshers.append { [weak self, weak button] in
            guard let self, let button else { return }
            button.state = (self.value(option) != inverted) ? .on : .off
            button.isEnabled = enabledWhen?() ?? true
        }
        return button
    }

    private func radio(_ title: String, _ option: FolderOption, is value: Bool, enabledWhen: (() -> Bool)? = nil) -> NSButton {
        let button = ClosureButton(radioButtonWithTitle: title)
        button.handler = { [weak self] in self?.set(option, value) }
        refreshers.append { [weak self, weak button] in
            guard let self, let button else { return }
            button.state = self.value(option) == value ? .on : .off
            button.isEnabled = enabledWhen?() ?? true
        }
        return button
    }

    private func indented(_ view: NSView, by amount: CGFloat = 20) -> NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: amount),
            view.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor),
            view.topAnchor.constraint(equalTo: wrapper.topAnchor),
            view.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        return wrapper
    }

    private func note(_ text: String, width: CGFloat = 330) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.preferredMaxLayoutWidth = width
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.required, for: .vertical)
        return label
    }

    // MARK: General

    private func generalTab() -> NSView {
        for location in StartLocation.available { startPopup.addItem(withTitle: location.title) }
        startPopup.target = self
        startPopup.action = #selector(startChanged)
        let startRow = NSStackView(views: [NSTextField.label(String(localized: "Open Arbor to:")), startPopup])
        startRow.spacing = 8

        for choice in HotKeyChoice.allCases { hotKeyPopup.addItem(withTitle: choice.title) }
        hotKeyPopup.target = self
        hotKeyPopup.action = #selector(hotKeyChanged)
        loginBox.target = self
        loginBox.action = #selector(loginChanged)
        let hotKeyRow = NSStackView(views: [NSTextField.label(String(localized: "Open a window from any app:")), hotKeyPopup])
        hotKeyRow.spacing = 8
        let launch = group(String(localized: "Open from anywhere"), symbol: "keyboard", [
            hotKeyRow,
            loginBox,
            note(String(localized: "Like Win+E on Windows. The shortcut works while Arbor is running, so turn on Open Arbor at login too.")),
        ])

        let singleClick: () -> Bool = { [weak self] in self?.value(.singleClickToOpen) ?? false }
        let browse = group(String(localized: "Browse folders"), symbol: "macwindow.on.rectangle", [
            radio(String(localized: "Open each folder in the same window"), .openFoldersInNewWindow, is: false),
            radio(String(localized: "Open each folder in its own window"), .openFoldersInNewWindow, is: true),
        ])
        let click = group(String(localized: "Click items as follows"), symbol: "cursorarrow.click", [
            radio(String(localized: "Single-click to open an item (point to select)"), .singleClickToOpen, is: true),
            indented(radio(String(localized: "Always underline icon titles"), .underlineOnlyOnHover, is: false, enabledWhen: singleClick)),
            indented(radio(String(localized: "Underline icon titles only when I point at them"), .underlineOnlyOnHover, is: true, enabledWhen: singleClick)),
            radio(String(localized: "Double-click to open an item (single-click to select)"), .singleClickToOpen, is: false),
        ])

        let clearButton = NSButton(title: String(localized: "Clear"), target: self, action: #selector(clearHistory))
        let clearRow = NSStackView(views: [NSTextField.label(String(localized: "Clear Arbor history")), clearButton])
        clearRow.spacing = 12
        let privacy = group(String(localized: "Privacy"), symbol: "hand.raised", [
            check(String(localized: "Show recently used files (in Go › Recent Files)"), .showRecentFiles),
            check(String(localized: "Show frequently used folders (in the navigation pane)"), .showFrequentFolders),
            clearRow,
        ])

        let makeDefault = NSButton(title: String(localized: "Use Arbor to Open Folders"), target: self, action: #selector(makeDefault))
        let restoreFinder = NSButton(title: String(localized: "Restore Finder"), target: self, action: #selector(restoreFinder))
        let defaultButtons = NSStackView(views: [makeDefault, restoreFinder])
        let viewer = group(String(localized: "Default folder viewer"), symbol: "folder", [defaultButtons, defaultStatus])

        return page([startRow, launch, browse, click, privacy, viewer], restore: #selector(restoreGeneral))
    }

    // MARK: View

    private func viewTab() -> NSView {
        let applyFolders = NSButton(title: String(localized: "Apply to Folders"), target: self, action: #selector(applyToFolders))
        let resetFolders = NSButton(title: String(localized: "Reset Folders"), target: self, action: #selector(resetFolders))
        let folderViews = group(String(localized: "Folder views"), symbol: "folder", [
            note(String(localized: "You can apply this view (such as Details or Icons) to all folders.")),
            NSStackView(views: [applyFolders, resetFolders]),
        ])

        let list = AdvancedSettingsList()
        list.add(header: String(localized: "Files and Folders"), symbol: "folder.fill", level: 0)
        list.add(check(String(localized: "Always show icons, never thumbnails"), .alwaysShowIcons), level: 1)
        list.add(check(String(localized: "Display file icon on thumbnails"), .fileIconOnThumbnails), level: 1)
        list.add(check(String(localized: "Display file size information in folder tips"), .folderTipSize), level: 1)
        list.add(check(String(localized: "Display the full path in the title bar"), .fullPathInTitleBar), level: 1)
        list.add(header: String(localized: "Hidden files and folders"), symbol: "folder", level: 1)
        list.add(radio(String(localized: "Don't show hidden files, folders, or drives"), .showHidden, is: false), level: 2)
        list.add(radio(String(localized: "Show hidden files, folders, and drives"), .showHidden, is: true), level: 2)
        list.add(check(String(localized: "Hide empty drives"), .hideEmptyDrives), level: 1)
        list.add(check(String(localized: "Hide extensions for known file types"), .showExtensions, inverted: true), level: 1)
        list.add(check(String(localized: "Hide protected operating system files (Recommended)"), .hideProtectedSystemFiles, confirm: { [weak self] checked in
            checked || self?.confirmShowProtectedFiles() == true
        }), level: 1)
        list.add(check(String(localized: "Restore previous folder windows at launch"), .restoreWindowsAtLaunch), level: 1)
        list.add(check(String(localized: "Show pop-up description for folder and desktop items"), .popUpDescriptions), level: 1)
        list.add(check(String(localized: "Show preview handlers in preview pane"), .previewHandlers), level: 1)
        list.add(check(String(localized: "Show status bar"), .showStatusBar), level: 1)
        list.add(check(String(localized: "Use Backspace to go back (otherwise it deletes)"), .backspaceGoesBack), level: 1)
        list.add(check(String(localized: "Use check boxes to select items"), .itemCheckBoxes), level: 1)
        list.add(header: String(localized: "When typing into list view"), symbol: "folder", level: 1)
        list.add(radio(String(localized: "Automatically type into the Search Box"), .typeIntoSearchBox, is: true), level: 2)
        list.add(radio(String(localized: "Select the typed item in the view"), .typeIntoSearchBox, is: false), level: 2)
        list.add(header: String(localized: "Navigation pane"), symbol: "sidebar.left", level: 0)
        list.add(check(String(localized: "Expand to open folder"), .expandToOpenFolder), level: 1)
        list.add(check(String(localized: "Show This Mac"), .showThisMac), level: 1)
        list.heightAnchor.constraint(equalToConstant: 450).isActive = true

        let advancedLabel = NSTextField.label(String(localized: "Advanced settings:"))
        return page([folderViews, advancedLabel, list], restore: #selector(restoreView))
    }

    // MARK: Search

    private func searchTab() -> NSView {
        let how = group(String(localized: "How to search"), symbol: "magnifyingglass", [
            note(String(localized: "Arbor searches folders directly, so every folder is treated as a non-indexed location. Results appear as they're found.")),
        ])
        let nonIndexed = group(String(localized: "When searching non-indexed locations"), symbol: "folder.badge.gearshape", [
            check(String(localized: "Include system directories"), .searchSystemDirectories),
            check(String(localized: "Include compressed files (ZIP)"), .searchCompressedFiles),
            check(String(localized: "Always search file names and contents (this might take several minutes)"), .searchFileContents),
        ])
        return page([how, nonIndexed], restore: #selector(restoreSearch))
    }

    // MARK: Actions

    @objc private func hotKeyChanged() {
        draftHotKey = HotKeyChoice.allCases[max(0, hotKeyPopup.indexOfSelectedItem)]
        refreshAll()
    }

    @objc private func loginChanged() {
        draftLoginItem = loginBox.state == .on
        refreshAll()
    }

    @objc private func startChanged() {
        let choices = StartLocation.available
        guard choices.indices.contains(startPopup.indexOfSelectedItem) else { return }
        draftStart = choices[startPopup.indexOfSelectedItem]
        refreshAll()
    }

    private func restore(_ options: [FolderOption]) {
        for option in options { draft[option] = option.defaultValue }
        refreshAll()
    }

    @objc private func restoreGeneral() {
        draftStart = .home
        draftHotKey = .off
        restore(FolderOption.generalTab)
    }

    @objc private func restoreView() { restore(FolderOption.viewTab) }
    @objc private func restoreSearch() { restore(FolderOption.searchTab) }

    @objc private func applyPressed() {
        Preferences.shared.apply(draft, startLocation: draftStart)
        if draftHotKey != Preferences.shared.hotKey {
            Preferences.shared.hotKey = draftHotKey
            if !GlobalHotKey.shared.apply(draftHotKey) {
                let alert = NSAlert()
                alert.messageText = String(localized: "Another app is already using \(draftHotKey.title).")
                alert.informativeText = String(localized: "Choose a different shortcut.")
                alert.runModal()
            }
        }
        if draftLoginItem != LoginItem.isEnabled, let problem = LoginItem.set(draftLoginItem) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Arbor couldn't change Open at login.")
            alert.informativeText = problem
            alert.runModal()
            draftLoginItem = LoginItem.isEnabled
        }
        refreshAll()
    }

    @objc private func okPressed() {
        applyPressed()
        window?.close()
    }

    @objc private func cancelPressed() {
        window?.close()
    }

    private func confirm(_ message: String, info: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Yes"))
        alert.addButton(withTitle: String(localized: "No"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmShowProtectedFiles() -> Bool {
        confirm(
            String(localized: "Warning"),
            info: String(localized: "You have chosen to display protected operating system files (such as .DS_Store and the system folders at the top of your startup disk). macOS needs these files to run properly. Deleting or editing them can make your Mac unusable.\n\nAre you sure you want to display these files?")
        )
    }

    @objc private func applyToFolders() {
        guard let browser = AppDelegate.shared.frontmostBrowser,
              confirm(String(localized: "Folder Views"), info: String(localized: "Do you want all folders to match this folder's view settings?")) else { return }
        FolderViewStore.shared.applyToAllFolders(browser.viewSettings)
        NotificationCenter.default.post(name: .arborPreferencesChanged, object: nil)
    }

    @objc private func resetFolders() {
        guard confirm(String(localized: "Folder Views"), info: String(localized: "Do you want to reset all folders to the default view settings?")) else { return }
        FolderViewStore.shared.reset()
        NotificationCenter.default.post(name: .arborPreferencesChanged, object: nil)
    }

    @objc private func clearHistory() {
        RecentItems.shared.clear()
    }

    @objc private func makeDefault() {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .folder) { [weak self] error in
            DispatchQueue.main.async {
                if let error { FileOperationService.shared.present(error, window: self?.window) }
                self?.refreshAll()
            }
        }
    }

    @objc private func restoreFinder() {
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        NSWorkspace.shared.setDefaultApplication(at: finder, toOpen: .folder) { [weak self] error in
            DispatchQueue.main.async {
                if let error { FileOperationService.shared.present(error, window: self?.window) }
                self?.refreshAll()
            }
        }
    }
}

/// A checkbox or radio button that runs a closure.
final class ClosureButton: NSButton {
    var handler: (() -> Void)?

    convenience init(checkboxWithTitle title: String) {
        self.init(frame: .zero)
        setButtonType(.switch)
        self.title = title
        configure()
    }

    convenience init(radioButtonWithTitle title: String) {
        self.init(frame: .zero)
        setButtonType(.radio)
        self.title = title
        configure()
    }

    private func configure() {
        target = self
        action = #selector(fire)
        font = .systemFont(ofSize: 12)
    }

    @objc private func fire() { handler?() }
}

/// The scrolling tree of check boxes and radio buttons under "Advanced settings:".
final class AdvancedSettingsList: NSScrollView {
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        borderType = .bezelBorder
        hasVerticalScroller = true
        autohidesScrollers = false
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func add(header title: String, symbol: String, level: Int) {
        let icon = NSImageView(image: NSImage.symbol(symbol, size: 12) ?? NSImage())
        icon.contentTintColor = .systemYellow
        let label = NSTextField.label(title, size: 12)
        let row = NSStackView(views: [icon, label])
        row.spacing = 5
        add(row, level: level)
    }

    func add(_ control: NSView, level: Int) {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: CGFloat(level) * 20),
            control.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            control.topAnchor.constraint(equalTo: row.topAnchor),
            control.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        stack.addArrangedSubview(row)
    }
}
