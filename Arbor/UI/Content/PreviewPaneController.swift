import AppKit
import Quartz

/// Explorer's preview pane (⌥P), powered by Quick Look.
final class PreviewPaneController: NSViewController {
    private var previewView: QLPreviewView?
    private let messageLabel = NSTextField.label(String(localized: "Select a file to preview."), size: 13, color: .secondaryLabelColor)
    private let nameLabel = NSTextField.label("", size: 13, weight: .semibold)
    private let infoLabel = NSTextField.label("", size: 11, color: .secondaryLabelColor)
    private var shownURL: URL?
    /// Used instead of Quick Look when "Show preview handlers in preview pane" is off.
    private let iconView = NSImageView()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        let preview = QLPreviewView(frame: .zero, style: .normal)
        preview?.translatesAutoresizingMaskIntoConstraints = false
        preview?.autostarts = true
        previewView = preview
        messageLabel.alignment = .center
        nameLabel.alignment = .center
        infoLabel.alignment = .center
        infoLabel.maximumNumberOfLines = 3
        if let preview { root.addSubview(preview) }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(iconView)
        [messageLabel, nameLabel, infoLabel].forEach(root.addSubview)
        var constraints = [
            iconView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -30),
            iconView.widthAnchor.constraint(equalToConstant: 128),
            iconView.heightAnchor.constraint(equalToConstant: 128),
            messageLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -24),
            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            infoLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            infoLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            infoLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            infoLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ]
        if let preview {
            constraints += [
                preview.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
                preview.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
                preview.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
                preview.bottomAnchor.constraint(equalTo: nameLabel.topAnchor, constant: -10),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        view = root
        show([])
    }

    func show(_ items: [FileItem]) {
        guard isViewLoaded else { return }
        if items.count == 1, let item = items.first {
            let handlers = Preferences.shared[.previewHandlers]
            messageLabel.isHidden = true
            previewView?.isHidden = !handlers
            iconView.isHidden = handlers
            nameLabel.isHidden = false
            infoLabel.isHidden = false
            if handlers {
                if shownURL?.isSameItem(as: item.url) != true {
                    previewView?.previewItem = item.url as NSURL
                    shownURL = item.url
                }
            } else {
                previewView?.previewItem = nil
                shownURL = nil
                iconView.image = IconCache.icon(for: item.url)
            }
            nameLabel.stringValue = item.name
            var info = [item.kind]
            if let size = item.size { info.append(Format.bytes(size)) }
            if let modified = item.modified { info.append("Modified \(Format.date(modified))") }
            infoLabel.stringValue = info.joined(separator: " · ")
        } else {
            previewView?.previewItem = nil
            shownURL = nil
            previewView?.isHidden = true
            iconView.isHidden = true
            nameLabel.isHidden = true
            infoLabel.isHidden = true
            messageLabel.isHidden = false
            messageLabel.stringValue = items.isEmpty ? String(localized: "Select a file to preview.") : String(localized: "\(items.count) items selected")
        }
    }

    deinit {
        previewView?.close()
    }
}
