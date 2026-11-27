import AppKit

protocol ThisMacDelegate: AnyObject {
    func thisMac(_ controller: ThisMacViewController, open url: URL)
    func thisMac(_ controller: ThisMacViewController, menuFor url: URL?, isVolume: Bool) -> NSMenu?
    func thisMacSelectionDidChange(_ controller: ThisMacViewController)
}

/// Explorer's "This PC": user folders plus "Devices and drives" with free-space bars.
final class ThisMacViewController: NSViewController {
    weak var delegate: ThisMacDelegate?
    private let stack = NSStackView()
    private var tiles: [TileView] = []
    private(set) var selectedURL: URL?

    var itemCount: Int { tiles.count }

    var selectedItem: FileItem? { selectedURL.flatMap(FileItem.init(url:)) }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 18, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        document.onBackgroundClick = { [weak self] in self?.select(nil) }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        view = scroll
    }

    func reload() {
        _ = view
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tiles = []

        let fm = FileManager.default
        let folderDirs: [FileManager.SearchPathDirectory] = [.desktopDirectory, .documentDirectory, .downloadsDirectory, .musicDirectory, .picturesDirectory, .moviesDirectory]
        var folders = folderDirs.compactMap { fm.userFolderURL($0)?.normalizedFolder }
        folders.insert(fm.realHomeDirectory.normalizedFolder, at: 0)
        if let apps = fm.urls(for: .applicationDirectory, in: .localDomainMask).first { folders.append(apps.normalizedFolder) }
        let folderTiles = folders.filter { fm.fileExists(atPath: $0.path) }.map { url in
            TileView(url: url, title: Location.displayName(of: url), subtitle: nil, volume: nil)
        }
        addSection(String(localized: "Folders (\(folderTiles.count))"), tiles: folderTiles, tileSize: NSSize(width: Self.columnWidth, height: 58))

        let volumes = VolumeService.visibleVolumes()
        func driveTile(_ volume: VolumeInfo) -> TileView {
            TileView(
                url: volume.url,
                title: volume.name,
                subtitle: String(localized: "\(Format.bytes(volume.availableCapacity)) free of \(Format.bytes(volume.totalCapacity))"),
                volume: volume
            )
        }
        let driveTiles = volumes.filter { !$0.isNetwork }.map(driveTile)
        addSection(String(localized: "Devices and drives (\(driveTiles.count))"), tiles: driveTiles, tileSize: NSSize(width: Self.columnWidth, height: 68))

        // Explorer's "Network locations": connected network volumes, plus mapped servers that aren't connected yet.
        var networkTiles = volumes.filter(\.isNetwork).map(driveTile)
        for location in NetworkLocations.saved {
            guard let url = location.url, NetworkLocations.mountedURL(for: url) == nil else { continue }
            networkTiles.append(TileView(url: url, title: location.displayName, subtitle: String(localized: "Disconnected"), volume: nil, icon: NSImage(named: NSImage.networkName)))
        }
        if !networkTiles.isEmpty {
            addSection(String(localized: "Network locations (\(networkTiles.count))"), tiles: networkTiles, tileSize: NSSize(width: Self.columnWidth, height: 68))
        }

        if let selectedURL, !tiles.contains(where: { Self.same($0.url, selectedURL) }) { self.selectedURL = nil }
        for tile in tiles { tile.isSelected = selectedURL.map { Self.same(tile.url, $0) } ?? false }
    }

    /// Both sections share one column width so folders and drives line up in the same columns.
    static let columnWidth: CGFloat = 236

    private func addSection(_ title: String, tiles sectionTiles: [TileView], tileSize: NSSize) {
        // Indent the header so it starts where the tile icons start.
        let header = NSTextField.label(title, size: 13, weight: .semibold, color: .secondaryLabelColor)
        let headerRow = NSView()
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: TileView.iconInset),
            header.trailingAnchor.constraint(lessThanOrEqualTo: headerRow.trailingAnchor),
            header.topAnchor.constraint(equalTo: headerRow.topAnchor, constant: 6),
            header.bottomAnchor.constraint(equalTo: headerRow.bottomAnchor),
        ])
        stack.addArrangedSubview(headerRow)
        let flow = FlowView()
        flow.tileSize = tileSize
        for tile in sectionTiles {
            tile.onClick = { [weak self, weak tile] clickCount in
                guard let self, let tile else { return }
                self.select(tile.url)
                if clickCount == 2 { self.delegate?.thisMac(self, open: tile.url) }
            }
            tile.menuProvider = { [weak self, weak tile] in
                guard let self, let tile else { return nil }
                self.select(tile.url)
                return self.delegate?.thisMac(self, menuFor: tile.url, isVolume: tile.volume != nil)
            }
            flow.addSubview(tile)
        }
        stack.addArrangedSubview(flow)
        flow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        stack.setCustomSpacing(14, after: flow)
        tiles += sectionTiles
    }

    /// File URLs compare by path; server URLs (smb://…) by address.
    static func same(_ a: URL, _ b: URL) -> Bool {
        a.isFileURL && b.isFileURL ? a.isSameItem(as: b) : a.absoluteString == b.absoluteString
    }

    func select(_ url: URL?) {
        selectedURL = url
        for tile in tiles { tile.isSelected = url.map { Self.same(tile.url, $0) } ?? false }
        delegate?.thisMacSelectionDidChange(self)
    }

    func openSelection() {
        guard let selectedURL else { return }
        delegate?.thisMac(self, open: selectedURL)
    }
}

final class FlippedView: NSView {
    var onBackgroundClick: (() -> Void)?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { onBackgroundClick?() }
}

/// Lays out fixed-size tiles left to right, wrapping into rows.
final class FlowView: NSView {
    var tileSize = NSSize(width: 230, height: 58)
    var spacing: CGFloat = 8
    private lazy var heightConstraint: NSLayoutConstraint = {
        let constraint = heightAnchor.constraint(equalToConstant: tileSize.height)
        constraint.isActive = true
        return constraint
    }()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        var y: CGFloat = 0
        for view in subviews {
            if x > 0, x + tileSize.width > bounds.width {
                x = 0
                y += tileSize.height + spacing
            }
            view.frame = NSRect(origin: NSPoint(x: x, y: y), size: tileSize)
            x += tileSize.width + spacing
        }
        let height = subviews.isEmpty ? 0 : y + tileSize.height
        if heightConstraint.constant != height { heightConstraint.constant = height }
    }
}

/// A folder or drive tile on the This Mac page.
final class TileView: NSView {
    static let iconInset: CGFloat = 10
    static let iconSize: CGFloat = 48
    let url: URL
    let volume: VolumeInfo?
    var onClick: ((Int) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var isSelected = false { didSet { needsDisplay = true } }
    private var isHovered = false { didSet { needsDisplay = true } }

    init(url: URL, title: String, subtitle: String?, volume: VolumeInfo?, icon customIcon: NSImage? = nil) {
        self.url = url
        self.volume = volume
        super.init(frame: .zero)
        let icon = NSImageView(image: customIcon ?? IconCache.icon(for: url))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField.label(title, size: 13)
        addSubview(icon)
        addSubview(titleLabel)
        var constraints = [
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.iconInset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ]
        if volume != nil || subtitle != nil {
            let bar = CapacityBar(fraction: volume?.usedFraction ?? 0)
            bar.isHidden = volume == nil  // a disconnected server has no capacity to show
            let detail = NSTextField.label(subtitle ?? "", size: 11, color: .secondaryLabelColor)
            addSubview(bar)
            addSubview(detail)
            constraints += [
                titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 11),
                bar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                bar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
                bar.heightAnchor.constraint(equalToConstant: 12),
                detail.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                detail.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 3),
                detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            ]
        } else {
            constraints.append(titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        if Preferences.shared[.popUpDescriptions] { toolTip = url.isFileURL ? url.path : url.absoluteString }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onClick?(event.clickCount) }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || isHovered else { return }
        let alpha: CGFloat = isSelected ? 0.22 : 0.08
        NSColor.controlAccentColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

/// The used-space bar under each drive (turns red when nearly full, like Explorer).
final class CapacityBar: NSView {
    private let fraction: Double

    init(fraction: Double) {
        self.fraction = min(max(fraction, 0), 1)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        bounds.fill()
        let fill = NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        (fraction > 0.9 ? NSColor.systemRed : NSColor.controlAccentColor).setFill()
        fill.fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}
