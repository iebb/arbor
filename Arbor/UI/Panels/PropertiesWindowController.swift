import AppKit

/// Explorer's Properties dialog (⌘I / ⌥Return): type, location, size on disk, contents, dates, attributes.
final class PropertiesWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [PropertiesWindowController] = []

    @discardableResult
    static func show(for urls: [URL]) -> PropertiesWindowController {
        let controller = PropertiesWindowController(urls: urls)
        open.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    private let urls: [URL]
    private let sizeLabel = NSTextField.label(String(localized: "Calculating…"))
    private let diskSizeLabel = NSTextField.label(String(localized: "Calculating…"))
    private let containsLabel = NSTextField.label(String(localized: "Calculating…"))
    private let cancelFlag = CancellationFlag()

    private init(urls: [URL]) {
        self.urls = urls
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self
        build()
        panel.center()
        calculateSize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var single: URL? { urls.count == 1 ? urls[0] : nil }

    private func build() {
        guard let window else { return }
        let fm = FileManager.default
        let items = urls.compactMap(FileItem.init(url:))
        let folders = items.filter(\.isFolder).count
        let files = items.count - folders

        let title: String
        if let single {
            title = Location.displayName(of: single)
        } else {
            title = String(localized: "\(files) Files, \(folders) Folders")
        }
        window.title = String(localized: "\(title) Properties")

        let icon = NSImageView(image: single.map { IconCache.icon(for: $0) } ?? (NSImage(named: NSImage.multipleDocumentsName) ?? NSImage()))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let name = NSTextField(string: single?.lastPathComponent ?? title)
        name.isEditable = false
        name.isSelectable = true
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let header = NSStackView(views: [icon, name])
        header.spacing = 14

        var rows: [[NSView]] = []
        func row(_ label: String, _ value: NSView) {
            let caption = NSTextField.label(label + ":", color: .secondaryLabelColor)
            caption.alignment = .right
            rows.append([caption, value])
        }
        func row(_ label: String, _ text: String) {
            let value = NSTextField.label(text)
            value.isSelectable = true
            value.lineBreakMode = .byTruncatingMiddle
            row(label, value)
        }

        if let single, let item = items.first {
            row(String(localized: "Type of file"), item.isFolder ? String(localized: "File folder") : "\(item.kind)\(item.fileExtension.isEmpty ? "" : " (.\(item.fileExtension))")")
            if !item.isFolder, let app = NSWorkspace.shared.urlForApplication(toOpen: single) {
                row(String(localized: "Opens with"), fm.displayName(atPath: app.path))
            }
        } else {
            row(String(localized: "Type"), files > 0 && folders > 0 ? String(localized: "Multiple types") : (folders > 0 ? String(localized: "All of type File folder") : String(localized: "Multiple files")))
        }
        let parents = Set(urls.map { $0.parentFolder.path })
        let rawLocation = parents.count == 1 ? parents.first! : String(localized: "Various folders")
        #if DEBUG
        let shownLocation = parents.count == 1 ? DemoRedactor.redactPath(rawLocation) : rawLocation
        #else
        let shownLocation = rawLocation
        #endif
        row(String(localized: "Location"), shownLocation)
        rows.append([NSView(), NSView()])
        row(String(localized: "Size"), sizeLabel)
        row(String(localized: "Size on disk"), diskSizeLabel)
        if folders > 0 { row(String(localized: "Contains"), containsLabel) }

        if let single {
            let values = try? single.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .contentAccessDateKey])
            rows.append([NSView(), NSView()])
            row(String(localized: "Created"), Format.longDate(values?.creationDate))
            row(String(localized: "Modified"), Format.longDate(values?.contentModificationDate))
            row(String(localized: "Accessed"), Format.longDate(values?.contentAccessDate))
        }

        rows.append([NSView(), NSView()])
        let locked = NSButton(checkboxWithTitle: String(localized: "Read-only (Locked)"), target: self, action: #selector(toggleLocked(_:)))
        let hidden = NSButton(checkboxWithTitle: String(localized: "Hidden"), target: self, action: #selector(toggleHidden(_:)))
        let flags = urls.compactMap { try? $0.resourceValues(forKeys: [.isUserImmutableKey, .isHiddenKey]) }
        locked.state = state(flags.map { $0.isUserImmutable ?? false })
        hidden.state = state(flags.map { $0.isHidden ?? false })
        locked.allowsMixedState = true
        hidden.allowsMixedState = true
        let attributes = NSStackView(views: [locked, hidden])
        attributes.orientation = .vertical
        attributes.alignment = .leading
        row(String(localized: "Attributes"), attributes)

        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 100
        grid.rowSpacing = 7
        grid.columnSpacing = 10
        for index in 0..<grid.numberOfRows where (rows[index].first?.className == NSView.className()) {
            grid.row(at: index).height = 4
        }

        let ok = NSButton(title: String(localized: "OK"), target: self, action: #selector(closeWindow))
        ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [ok])

        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [header, separator, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -20).isActive = true

        let content = WindowBackgroundView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 440),
        ])
        window.contentView = content
    }

    private func state(_ values: [Bool]) -> NSControl.StateValue {
        if values.allSatisfy({ $0 }) { return .on }
        if values.allSatisfy({ !$0 }) { return .off }
        return .mixed
    }

    /// Walks folders in the background, updating the size as it goes (like Explorer's ticking counter).
    private func calculateSize() {
        let urls = self.urls
        let flag = cancelFlag
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var bytes: Int64 = 0
            var allocated: Int64 = 0
            var fileCount = 0
            var folderCount = 0
            var lastUpdate = Date()
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey]

            func add(_ url: URL) {
                guard let values = try? url.resourceValues(forKeys: keys) else { return }
                if values.isDirectory == true, values.isSymbolicLink != true {
                    folderCount += 1
                } else {
                    fileCount += 1
                    bytes += Int64(values.fileSize ?? 0)
                    allocated += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                }
            }

            for url in urls {
                let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if !isFolder {
                    add(url)
                    continue
                }
                let enumerator = FileManager().enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
                while let child = enumerator?.nextObject() as? URL {
                    if flag.isCancelled { return }
                    add(child)
                    if Date().timeIntervalSince(lastUpdate) > 0.2 {
                        lastUpdate = Date()
                        let snapshot = (bytes, allocated, fileCount, folderCount)
                        DispatchQueue.main.async { self?.showSize(snapshot, done: false) }
                    }
                }
            }
            let snapshot = (bytes, allocated, fileCount, folderCount)
            DispatchQueue.main.async { self?.showSize(snapshot, done: true) }
        }
    }

    private func showSize(_ value: (Int64, Int64, Int, Int), done: Bool) {
        sizeLabel.stringValue = Format.bytesWithExact(value.0) + (done ? "" : "…")
        diskSizeLabel.stringValue = Format.bytesWithExact(value.1) + (done ? "" : "…")
        containsLabel.stringValue = String(localized: "\(Format.number(Int64(value.2))) Files, \(Format.number(Int64(value.3))) Folders")
    }

    @objc private func toggleLocked(_ sender: NSButton) {
        let on = sender.state != .off
        sender.state = on ? .on : .off
        apply { values in values.isUserImmutable = on }
    }

    @objc private func toggleHidden(_ sender: NSButton) {
        let on = sender.state != .off
        sender.state = on ? .on : .off
        apply { values in values.isHidden = on }
    }

    private func apply(_ change: (inout URLResourceValues) -> Void) {
        for var url in urls {
            var values = URLResourceValues()
            change(&values)
            do {
                try url.setResourceValues(values)
            } catch {
                FileOperationService.shared.present(error, window: window)
                break
            }
        }
        let folders = Array(Set(urls.map { $0.parentFolder.pathKey })).map { URL(fileURLWithPath: $0, isDirectory: true) }
        NotificationCenter.default.post(name: .arborFoldersChanged, object: nil, userInfo: ["folders": folders])
    }

    @objc private func closeWindow() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        cancelFlag.cancel()
        PropertiesWindowController.open.removeAll { $0 === self }
    }
}
