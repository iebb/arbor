import AppKit

protocol AddressBarDelegate: AnyObject {
    func addressBarGoBack()
    func addressBarGoForward()
    func addressBarGoUp()
    func addressBarRefresh()
    func addressBarNavigate(to location: Location)
    /// Returns false to keep the address in edit mode (e.g. the path wasn't found).
    func addressBarSubmit(path: String) -> Bool
    func addressBarSearch(_ query: String)
    func addressBarDidFinishEditing()
    func addressBarHistoryMenu(back: Bool) -> NSMenu?
    func addressBarSubfolderMenu(for location: Location) -> NSMenu
}

/// One clickable step in the breadcrumb trail.
struct BreadcrumbSegment {
    let title: String
    let location: Location
}

enum Breadcrumbs {
    static func segments(for location: Location) -> [BreadcrumbSegment] {
        switch location {
        case .thisMac:
            return [BreadcrumbSegment(title: "This Mac", location: .thisMac)]
        case .folder(let url):
            return folderSegments(url)
        case .search(let root, _):
            return folderSegments(root) + [BreadcrumbSegment(title: "Search Results in \(Location.displayName(of: root))", location: location)]
        }
    }

    private static func folderSegments(_ url: URL) -> [BreadcrumbSegment] {
        var result = [BreadcrumbSegment(title: "This Mac", location: .thisMac)]
        let volumes = VolumeService.mountedVolumes()
        let volumeURL = VolumeService.volume(containing: url, in: volumes)?.url ?? URL(fileURLWithPath: "/", isDirectory: true)
        result.append(BreadcrumbSegment(title: Location.displayName(of: volumeURL), location: .folder(volumeURL)))
        for folder in url.folderChain(below: volumeURL) {
            result.append(BreadcrumbSegment(title: Location.displayName(of: folder), location: .folder(folder)))
        }
        return result
    }

    static func icon(for location: Location) -> NSImage? {
        switch location {
        case .thisMac: return NSImage(named: NSImage.computerName)
        case .folder(let url): return IconCache.icon(for: url)
        case .search: return NSImage.symbol("magnifyingglass", size: 13)
        }
    }
}

/// Explorer's address row: ← → ↑ ⟳, a breadcrumb address box you can click to type in, and a search box.
final class AddressBarView: NSView, NSTextFieldDelegate, NSSearchFieldDelegate {
    weak var delegate: AddressBarDelegate?

    let backButton = HoverButton(symbol: "arrow.left", toolTip: "Back (⌥←)", target: nil, action: nil)
    let forwardButton = HoverButton(symbol: "arrow.right", toolTip: "Forward (⌥→)", target: nil, action: nil)
    let upButton = HoverButton(symbol: "arrow.up", toolTip: "Up to parent folder (⌥↑)", target: nil, action: nil)
    let refreshButton = HoverButton(symbol: "arrow.clockwise", toolTip: "Refresh (F5)", target: nil, action: nil)
    let addressBox = AddressBoxView()
    let breadcrumbs = BreadcrumbView()
    let pathField = NSTextField()
    let searchField = NSSearchField()

    private var location: Location = .thisMac
    private var cancelRequested = false
    private var lastTypedLength = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setUp() {
        for (button, action) in [(backButton, #selector(back)), (forwardButton, #selector(forward)), (upButton, #selector(up)), (refreshButton, #selector(refresh))] {
            button.target = self
            button.action = action
        }

        addressBox.translatesAutoresizingMaskIntoConstraints = false
        addressBox.onClick = { [weak self] in self?.beginEditing() }

        breadcrumbs.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbs.onNavigate = { [weak self] location in self?.delegate?.addressBarNavigate(to: location) }
        breadcrumbs.menuProvider = { [weak self] location in self?.delegate?.addressBarSubfolderMenu(for: location) ?? NSMenu() }
        breadcrumbs.onClickEmpty = { [weak self] in self?.beginEditing() }

        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.isBordered = false
        pathField.drawsBackground = false
        pathField.focusRingType = .none
        pathField.font = .systemFont(ofSize: 13)
        pathField.usesSingleLineMode = true
        pathField.cell?.isScrollable = true
        pathField.cell?.wraps = false
        pathField.lineBreakMode = .byClipping
        pathField.delegate = self
        pathField.isHidden = true

        addressBox.addSubview(breadcrumbs)
        addressBox.addSubview(pathField)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search"
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self
        searchField.controlSize = .large

        [backButton, forwardButton, upButton, refreshButton, addressBox, searchField].forEach(addSubview)

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            upButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 2),
            upButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            refreshButton.leadingAnchor.constraint(equalTo: upButton.trailingAnchor, constant: 2),
            refreshButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            addressBox.leadingAnchor.constraint(equalTo: refreshButton.trailingAnchor, constant: 8),
            addressBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            addressBox.heightAnchor.constraint(equalToConstant: 28),

            breadcrumbs.leadingAnchor.constraint(equalTo: addressBox.leadingAnchor, constant: 2),
            breadcrumbs.trailingAnchor.constraint(equalTo: addressBox.trailingAnchor, constant: -2),
            breadcrumbs.topAnchor.constraint(equalTo: addressBox.topAnchor),
            breadcrumbs.bottomAnchor.constraint(equalTo: addressBox.bottomAnchor),

            pathField.leadingAnchor.constraint(equalTo: addressBox.leadingAnchor, constant: 8),
            pathField.trailingAnchor.constraint(equalTo: addressBox.trailingAnchor, constant: -8),
            pathField.centerYAnchor.constraint(equalTo: addressBox.centerYAnchor),

            searchField.leadingAnchor.constraint(equalTo: addressBox.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.22),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }

    func display(location: Location, canGoBack: Bool, canGoForward: Bool, canGoUp: Bool) {
        self.location = location
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        upButton.isEnabled = canGoUp
        backButton.menu = delegate?.addressBarHistoryMenu(back: true)
        forwardButton.menu = delegate?.addressBarHistoryMenu(back: false)
        breadcrumbs.set(Breadcrumbs.segments(for: location), icon: Breadcrumbs.icon(for: location))
        let scope = location.scopeURL.map { Location.displayName(of: $0) } ?? "This Mac"
        searchField.placeholderString = "Search \(scope)"
        if case .search(_, let query) = location {
            if searchField.stringValue != query { searchField.stringValue = query }
        } else {
            searchField.stringValue = ""
            if let editor = searchField.currentEditor(), window?.firstResponder === editor {
                window?.makeFirstResponder(nil)
            }
        }
        searchField.isEnabled = location.scopeURL != nil
        if isEditingPath { endEditing() }
    }

    // MARK: Path editing

    var isEditingPath: Bool { !pathField.isHidden }

    func beginEditing() {
        pathField.stringValue = location.editablePath
        lastTypedLength = (pathField.stringValue as NSString).length
        pathField.isHidden = false
        breadcrumbs.isHidden = true
        addressBox.isEditing = true
        window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
    }

    private func endEditing() {
        pathField.isHidden = true
        breadcrumbs.isHidden = false
        addressBox.isEditing = false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === pathField, selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelRequested = true
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) === pathField else { return }
        let movement = notification.userInfo?["NSTextMovement"] as? Int ?? 0
        let cancelled = cancelRequested
        cancelRequested = false
        if !cancelled, movement == NSTextMovement.return.rawValue {
            let text = pathField.stringValue
            endEditing()
            if delegate?.addressBarSubmit(path: text) == false {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.beginEditing()
                    self.pathField.stringValue = text
                }
            }
            return
        }
        endEditing()
        if cancelled { delegate?.addressBarDidFinishEditing() }
    }

    /// Inline autocomplete of folder names as you type a path.
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === pathField,
              let editor = pathField.currentEditor() as? NSTextView else { return }
        let text = editor.string
        let length = (text as NSString).length
        defer { lastTypedLength = length }
        guard length > lastTypedLength, editor.selectedRange().location == length else { return }

        let expanded = (text as NSString).expandingTildeInPath
        guard let slash = expanded.lastIndex(of: "/") else { return }
        let directory = String(expanded[...slash])
        let prefix = String(expanded[expanded.index(after: slash)...])
        guard !prefix.isEmpty else { return }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { !$0.hasPrefix(".") || prefix.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard let match = names.first(where: { name in
            var isDir: ObjCBool = false
            return name.lowercased().hasPrefix(prefix.lowercased())
                && FileManager.default.fileExists(atPath: directory + name, isDirectory: &isDir) && isDir.boolValue
        }) else { return }
        let remainder = String(match.dropFirst(prefix.count))
        guard !remainder.isEmpty else { return }
        editor.replaceCharacters(in: NSRange(location: length, length: 0), with: remainder)
        editor.setSelectedRange(NSRange(location: length, length: (remainder as NSString).length))
    }

    // MARK: Buttons and search

    @objc private func back() { delegate?.addressBarGoBack() }
    @objc private func forward() { delegate?.addressBarGoForward() }
    @objc private func up() { delegate?.addressBarGoUp() }
    @objc private func refresh() { delegate?.addressBarRefresh() }

    @objc private func searchChanged() {
        delegate?.addressBarSearch(searchField.stringValue)
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }
}

/// The rounded address box. Clicking empty space in it switches to typing.
final class AddressBoxView: NSView {
    var onClick: (() -> Void)?
    var isEditing = false { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = (isEditing ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.borderWidth = isEditing ? 2 : 1
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// Breadcrumb trail: "This Mac › Macintosh HD › Users › you", each with a › menu of subfolders.
/// When space runs out, the leading segments collapse into a « menu, like Explorer.
final class BreadcrumbView: NSView {
    var onNavigate: ((Location) -> Void)?
    var menuProvider: ((Location) -> NSMenu)?
    var onClickEmpty: (() -> Void)?

    private var segments: [BreadcrumbSegment] = []
    private var segmentButtons: [NSButton] = []
    private var chevronButtons: [NSButton] = []
    private let iconView = NSImageView()
    private let overflowButton = NSButton()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        overflowButton.image = NSImage.symbol("chevron.left.2", size: 9, weight: .semibold)
        overflowButton.bezelStyle = .recessed
        overflowButton.showsBorderOnlyWhileMouseInside = true
        overflowButton.target = self
        overflowButton.action = #selector(showOverflow(_:))
        overflowButton.toolTip = "Previous locations"
        addSubview(overflowButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(_ newSegments: [BreadcrumbSegment], icon: NSImage?) {
        segmentButtons.forEach { $0.removeFromSuperview() }
        chevronButtons.forEach { $0.removeFromSuperview() }
        segments = newSegments
        iconView.image = icon
        segmentButtons = newSegments.enumerated().map { index, segment in
            let button = NSButton(title: segment.title, target: self, action: #selector(segmentClicked(_:)))
            button.bezelStyle = .recessed
            button.showsBorderOnlyWhileMouseInside = true
            button.font = .systemFont(ofSize: 13)
            button.tag = index
            button.lineBreakMode = .byTruncatingMiddle
            addSubview(button)
            return button
        }
        chevronButtons = newSegments.enumerated().map { index, _ in
            let button = NSButton(image: NSImage.symbol("chevron.right", size: 9, weight: .semibold) ?? NSImage(), target: self, action: #selector(chevronClicked(_:)))
            button.bezelStyle = .recessed
            button.showsBorderOnlyWhileMouseInside = true
            button.tag = index
            button.toolTip = "Show folders"
            addSubview(button)
            return button
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let buttonHeight: CGFloat = 22
        let y = (height - buttonHeight) / 2
        iconView.frame = NSRect(x: 6, y: (height - 16) / 2, width: 16, height: 16)
        var x: CGFloat = 26

        let widths = segmentButtons.map { min($0.fittingSize.width, 260) }
        let chevronWidth: CGFloat = 16
        let overflowWidth: CGFloat = 24
        let available = bounds.width - x - 4
        var first = 0
        func total(from start: Int) -> CGFloat {
            (start..<segments.count).reduce(0) { $0 + widths[$1] + chevronWidth }
        }
        while first < segments.count - 1, total(from: first) + (first > 0 ? overflowWidth : 0) > available {
            first += 1
        }

        overflowButton.isHidden = first == 0
        if first > 0 {
            overflowButton.frame = NSRect(x: x, y: y, width: overflowWidth - 2, height: buttonHeight)
            x += overflowWidth
        }
        for index in segments.indices {
            let visible = index >= first
            segmentButtons[index].isHidden = !visible
            chevronButtons[index].isHidden = !visible
            guard visible else { continue }
            let width = min(widths[index], max(40, bounds.width - x - chevronWidth - 4))
            segmentButtons[index].frame = NSRect(x: x, y: y, width: width, height: buttonHeight)
            x += width
            chevronButtons[index].frame = NSRect(x: x, y: y, width: chevronWidth, height: buttonHeight)
            x += chevronWidth
        }
        overflowButton.tag = first
    }

    override func mouseDown(with event: NSEvent) {
        onClickEmpty?()
    }

    @objc private func segmentClicked(_ sender: NSButton) {
        guard segments.indices.contains(sender.tag) else { return }
        onNavigate?(segments[sender.tag].location)
    }

    @objc private func chevronClicked(_ sender: NSButton) {
        guard segments.indices.contains(sender.tag), let menu = menuProvider?(segments[sender.tag].location) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func showOverflow(_ sender: NSButton) {
        let menu = NSMenu()
        for index in (0..<sender.tag).reversed() {
            let segment = segments[index]
            let item = NSMenuItem(title: segment.title, action: #selector(overflowItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = Breadcrumbs.icon(for: segment.location)?.menuSized
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func overflowItemChosen(_ sender: NSMenuItem) {
        onNavigate?(segments[sender.tag].location)
    }
}
