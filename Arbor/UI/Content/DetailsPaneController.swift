import AppKit
import CoreServices
import ImageIO

/// Windows 11 Explorer's Details pane (⌥⇧P): large preview/icon, file metadata, media dimensions,
/// folder size summary, and quick access to Properties.
final class DetailsPaneController: NSViewController {
    var onOpenProperties: (() -> Void)?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let subtitleLabel = NSTextField.label("", size: 12, color: .secondaryLabelColor)
    private let propertiesStack = NSStackView()
    private let propertiesButton = NSButton(title: String(localized: "Properties…"), target: nil, action: nil)

    private var shownKey = ""
    private var sizeCancelFlag: CancellationFlag?
    private weak var liveSizeLabel: NSTextField?
    private weak var liveContainsLabel: NSTextField?

    override func loadView() {
        let root = WindowBackgroundView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 128),
            imageView.heightAnchor.constraint(equalToConstant: 128),
        ])

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.isSelectable = true
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 2

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        propertiesStack.orientation = .vertical
        propertiesStack.alignment = .leading
        propertiesStack.spacing = 10
        propertiesStack.translatesAutoresizingMaskIntoConstraints = false

        propertiesButton.bezelStyle = .rounded
        propertiesButton.controlSize = .small
        propertiesButton.target = self
        propertiesButton.action = #selector(openProperties)
        propertiesButton.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 16, bottom: 18, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(imageView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.setCustomSpacing(14, after: subtitleLabel)
        stack.addArrangedSubview(separator)
        stack.setCustomSpacing(14, after: separator)
        stack.addArrangedSubview(propertiesStack)
        stack.setCustomSpacing(16, after: propertiesStack)
        stack.addArrangedSubview(propertiesButton)

        let document = FlippedClipContentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),

            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),

            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            propertiesStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])

        view = root
    }

    func show(_ items: [FileItem], location: Location, totalCount: Int) {
        guard isViewLoaded else { return }
        let key = items.map(\.url.pathKey).joined(separator: "\n") + "|\(location.title)|\(totalCount)"
        guard key != shownKey else { return }
        shownKey = key

        sizeCancelFlag?.cancel()
        sizeCancelFlag = nil
        liveSizeLabel = nil
        liveContainsLabel = nil
        propertiesStack.arrangedSubviews.forEach {
            propertiesStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if items.count == 1, let item = items.first {
            showSingle(item)
        } else if items.count > 1 {
            showMultiple(items)
        } else {
            showLocation(location, itemCount: totalCount)
        }
    }

    private func showSingle(_ item: FileItem) {
        titleLabel.stringValue = item.name
        subtitleLabel.stringValue = item.kind
        propertiesButton.isHidden = false
        setPreviewImage(for: item)

        let typeText = item.isFolder
            ? String(localized: "File folder")
            : "\(item.kind)\(item.fileExtension.isEmpty ? "" : " (.\(item.fileExtension))")"
        addRow(String(localized: "Type"), value: typeText)

        if item.isFolder {
            liveSizeLabel = addRow(String(localized: "Size"), value: String(localized: "Calculating…"))
            liveContainsLabel = addRow(String(localized: "Contains"), value: String(localized: "Calculating…"))
            calculateFolderSize(for: item.url)
        } else if let size = item.size {
            addRow(String(localized: "Size"), value: Format.bytesWithExact(size))
        }

        for (label, value) in mediaMetadata(for: item) {
            addRow(label, value: value)
        }

        if let modified = item.modified {
            addRow(String(localized: "Date modified"), value: Format.longDate(modified))
        }
        if let created = item.created {
            addRow(String(localized: "Date created"), value: Format.longDate(created))
        }
        let locationPath: String
        #if DEBUG
        locationPath = DemoRedactor.redactPath(item.url.parentFolder.path)
        #else
        locationPath = item.url.parentFolder.path
        #endif
        addRow(String(localized: "Location"), value: locationPath)
    }

    private func showMultiple(_ items: [FileItem]) {
        let folders = items.filter(\.isFolder).count
        let files = items.count - folders
        imageView.image = NSImage(named: NSImage.multipleDocumentsName) ?? NSImage.symbol("doc.on.doc", size: 64)
        titleLabel.stringValue = String(localized: "\(items.count) items selected")
        subtitleLabel.stringValue = String(localized: "\(files) Files, \(folders) Folders")
        propertiesButton.isHidden = false

        let fileBytes = items.filter { !$0.isFolder }.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        if files > 0 {
            addRow(String(localized: "Size"), value: Format.bytesWithExact(fileBytes))
        }
        let parents = Set(items.map { $0.url.parentFolder.path })
        addRow(String(localized: "Location"), value: parents.count == 1 ? parents.first! : String(localized: "Various folders"))
    }

    private func showLocation(_ location: Location, itemCount: Int) {
        switch location {
        case .thisMac:
            imageView.image = NSImage(named: NSImage.computerName)
            titleLabel.stringValue = String(localized: "This Mac")
            subtitleLabel.stringValue = Format.items(itemCount)
            propertiesButton.isHidden = true
        case .folder(let url):
            imageView.image = IconCache.icon(for: url)
            titleLabel.stringValue = Location.displayName(of: url)
            subtitleLabel.stringValue = Format.items(itemCount)
            propertiesButton.isHidden = false
            addRow(String(localized: "Type"), value: String(localized: "File folder"))
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey]) {
                if let modified = values.contentModificationDate {
                    addRow(String(localized: "Date modified"), value: Format.longDate(modified))
                }
                if let created = values.creationDate {
                    addRow(String(localized: "Date created"), value: Format.longDate(created))
                }
            }
            addRow(String(localized: "Location"), value: url.path)
        case .search(let root, let query):
            imageView.image = NSImage.symbol("magnifyingglass", size: 64)
            titleLabel.stringValue = String(localized: "Search Results")
            subtitleLabel.stringValue = Format.items(itemCount)
            propertiesButton.isHidden = true
            addRow(String(localized: "Query"), value: query)
            addRow(String(localized: "Location"), value: root.path)
        }
    }

    @discardableResult
    private func addRow(_ caption: String, value: String) -> NSTextField {
        let heading = NSTextField.label(caption, size: 11, weight: .medium, color: .secondaryLabelColor)
        let body = NSTextField(wrappingLabelWithString: value)
        body.font = .systemFont(ofSize: 12.5)
        body.textColor = .labelColor
        body.isSelectable = true
        body.lineBreakMode = .byTruncatingMiddle
        body.maximumNumberOfLines = 3
        body.translatesAutoresizingMaskIntoConstraints = false

        let container = NSStackView(views: [heading, body])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 2
        container.translatesAutoresizingMaskIntoConstraints = false
        propertiesStack.addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: propertiesStack.widthAnchor).isActive = true
        body.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor).isActive = true
        return body
    }

    private func setPreviewImage(for item: FileItem) {
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 0
        imageView.layer?.masksToBounds = false
        imageView.image = IconCache.icon(for: item.url)
        guard !Preferences.shared[.alwaysShowIcons], ThumbnailProvider.wantsThumbnail(item) else { return }
        let url = item.url
        if let cached = ThumbnailProvider.shared.cachedThumbnail(for: url, size: 128) {
            imageView.image = cached
            imageView.layer?.cornerRadius = 8
            imageView.layer?.masksToBounds = true
        } else {
            let scale = view.window?.backingScaleFactor ?? 2
            ThumbnailProvider.shared.requestThumbnail(for: url, size: 128, scale: scale) { [weak self] image in
                guard let self, self.shownKey.hasPrefix(url.pathKey + "|") else { return }
                self.imageView.image = image
                self.imageView.layer?.cornerRadius = 8
                self.imageView.layer?.masksToBounds = true
            }
        }
    }

    private func mediaMetadata(for item: FileItem) -> [(String, String)] {
        guard !item.isFolder else { return [] }
        var rows: [(String, String)] = []
        if let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int,
           let height = props[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 {
            rows.append((String(localized: "Dimensions"), "\(width) × \(height)"))
        } else if let mdItem = MDItemCreateWithURL(kCFAllocatorDefault, item.url as CFURL) {
            if let width = MDItemCopyAttribute(mdItem, kMDItemPixelWidth) as? Int,
               let height = MDItemCopyAttribute(mdItem, kMDItemPixelHeight) as? Int, width > 0, height > 0 {
                rows.append((String(localized: "Dimensions"), "\(width) × \(height)"))
            }
            if let duration = MDItemCopyAttribute(mdItem, kMDItemDurationSeconds) as? Double, duration > 0 {
                rows.append((String(localized: "Duration"), formatDuration(duration)))
            }
            if let pages = MDItemCopyAttribute(mdItem, kMDItemNumberOfPages) as? Int, pages > 0 {
                rows.append((String(localized: "Pages"), "\(pages)"))
            }
        }
        return rows
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private func calculateFolderSize(for url: URL) {
        let flag = CancellationFlag()
        sizeCancelFlag = flag
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var bytes: Int64 = 0
            var files = 0
            var folders = 0
            var lastUpdate = Date()
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
            let enumerator = FileManager().enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
            while let child = enumerator?.nextObject() as? URL {
                if flag.isCancelled { return }
                guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true, values.isSymbolicLink != true {
                    folders += 1
                } else {
                    files += 1
                    bytes += Int64(values.fileSize ?? 0)
                }
                if Date().timeIntervalSince(lastUpdate) > 0.25 {
                    lastUpdate = Date()
                    let snapshot = (bytes, files, folders)
                    DispatchQueue.main.async {
                        guard !flag.isCancelled else { return }
                        self?.updateFolderSummary(snapshot, done: false)
                    }
                }
            }
            let snapshot = (bytes, files, folders)
            DispatchQueue.main.async {
                guard !flag.isCancelled else { return }
                self?.updateFolderSummary(snapshot, done: true)
            }
        }
    }

    private func updateFolderSummary(_ snapshot: (Int64, Int, Int), done: Bool) {
        liveSizeLabel?.stringValue = Format.bytesWithExact(snapshot.0) + (done ? "" : "…")
        liveContainsLabel?.stringValue = String(localized: "\(Format.number(Int64(snapshot.1))) Files, \(Format.number(Int64(snapshot.2))) Folders")
    }

    @objc private func openProperties() {
        onOpenProperties?()
    }

    deinit {
        sizeCancelFlag?.cancel()
    }
}

private final class FlippedClipContentView: NSView {
    override var isFlipped: Bool { true }
}
