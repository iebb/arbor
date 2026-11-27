import AppKit

/// The things the command bar needs to know to enable its buttons.
struct CommandState {
    var canCreate = false
    var canCut = false
    var canCopy = false
    var canPaste = false
    var canRename = false
    var canShare = false
    var canDelete = false
    var previewVisible = false
}

protocol CommandBarDelegate: AnyObject {
    func commandBarNewMenu() -> NSMenu
    func commandBarSortMenu() -> NSMenu
    func commandBarViewMenu() -> NSMenu
    func commandBarMoreMenu() -> NSMenu
    func commandBarCut()
    func commandBarCopy()
    func commandBarPaste()
    func commandBarRename()
    func commandBarShare(from button: NSButton)
    func commandBarDelete()
    func commandBarTogglePreview()
}

/// Explorer's command bar: New ▾ | Cut Copy Paste Rename Share Delete | Sort ▾ View ▾ ⋯ … Preview.
final class CommandBarView: NSView {
    weak var delegate: CommandBarDelegate?

    private lazy var newButton = HoverButton(symbol: "plus.circle", title: "New", toolTip: "Create a new item", target: self, action: #selector(newPressed(_:)))
    private lazy var cutButton = HoverButton(symbol: "scissors", toolTip: "Cut (⌘X)", target: self, action: #selector(cutPressed))
    private lazy var copyButton = HoverButton(symbol: "doc.on.doc", toolTip: "Copy (⌘C)", target: self, action: #selector(copyPressed))
    private lazy var pasteButton = HoverButton(symbol: "doc.on.clipboard", toolTip: "Paste (⌘V)", target: self, action: #selector(pastePressed))
    private lazy var renameButton = HoverButton(symbol: "character.cursor.ibeam", toolTip: "Rename (F2)", target: self, action: #selector(renamePressed))
    private lazy var shareButton = HoverButton(symbol: "square.and.arrow.up", toolTip: "Share", target: self, action: #selector(sharePressed(_:)))
    private lazy var deleteButton = HoverButton(symbol: "trash", toolTip: "Delete (Del or ⌘⌫)", target: self, action: #selector(deletePressed))
    private lazy var sortButton = HoverButton(symbol: "arrow.up.arrow.down", title: "Sort", toolTip: "Sort items", target: self, action: #selector(sortPressed(_:)))
    private lazy var viewButton = HoverButton(symbol: "square.grid.2x2", title: "View", toolTip: "Change the layout", target: self, action: #selector(viewPressed(_:)))
    private lazy var moreButton = HoverButton(symbol: "ellipsis", toolTip: "See more", target: self, action: #selector(morePressed(_:)))
    private lazy var previewButton = HoverButton(symbol: "sidebar.right", title: "Preview", toolTip: "Preview pane (⌥P)", target: self, action: #selector(previewPressed))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let left = NSStackView(views: [
            newButton, separator(),
            cutButton, copyButton, pasteButton, renameButton, shareButton, deleteButton, separator(),
            sortButton, viewButton, separator(),
            moreButton,
        ])
        left.orientation = .horizontal
        left.spacing = 2
        left.translatesAutoresizingMaskIntoConstraints = false
        previewButton.setButtonType(.pushOnPushOff)
        addSubview(left)
        addSubview(previewButton)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            previewButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            previewButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            previewButton.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(box)
        NSLayoutConstraint.activate([
            wrapper.widthAnchor.constraint(equalToConstant: 11),
            wrapper.heightAnchor.constraint(equalToConstant: 28),
            box.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            box.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
        ])
        return wrapper
    }

    func update(_ state: CommandState) {
        newButton.isEnabled = state.canCreate
        cutButton.isEnabled = state.canCut
        copyButton.isEnabled = state.canCopy
        pasteButton.isEnabled = state.canPaste
        renameButton.isEnabled = state.canRename
        shareButton.isEnabled = state.canShare
        deleteButton.isEnabled = state.canDelete
        previewButton.state = state.previewVisible ? .on : .off
    }

    @objc private func newPressed(_ sender: HoverButton) { if let menu = delegate?.commandBarNewMenu() { sender.popUp(menu) } }
    @objc private func sortPressed(_ sender: HoverButton) { if let menu = delegate?.commandBarSortMenu() { sender.popUp(menu) } }
    @objc private func viewPressed(_ sender: HoverButton) { if let menu = delegate?.commandBarViewMenu() { sender.popUp(menu) } }
    @objc private func morePressed(_ sender: HoverButton) { if let menu = delegate?.commandBarMoreMenu() { sender.popUp(menu) } }
    @objc private func cutPressed() { delegate?.commandBarCut() }
    @objc private func copyPressed() { delegate?.commandBarCopy() }
    @objc private func pastePressed() { delegate?.commandBarPaste() }
    @objc private func renamePressed() { delegate?.commandBarRename() }
    @objc private func sharePressed(_ sender: NSButton) { delegate?.commandBarShare(from: sender) }
    @objc private func deletePressed() { delegate?.commandBarDelete() }
    @objc private func previewPressed() { delegate?.commandBarTogglePreview() }
}

/// Bottom status bar: "24 items | 3 items selected 1.20 MB" and the Details / Large icons toggles.
final class StatusBarView: NSView {
    var onViewModeSelected: ((ViewMode) -> Void)?
    private let label = NSTextField.label("", size: 11.5, color: .secondaryLabelColor)
    private let spinner = NSProgressIndicator()
    private lazy var detailsButton = HoverButton(symbol: "list.bullet.rectangle", toolTip: "Details (⌃⇧6)", target: self, action: #selector(detailsPressed))
    private lazy var iconsButton = HoverButton(symbol: "square.grid.2x2", toolTip: "Large icons (⌃⇧2)", target: self, action: #selector(iconsPressed))

    var viewMode: ViewMode = .details {
        didSet {
            detailsButton.state = viewMode == .details ? .on : .off
            iconsButton.state = viewMode == .largeIcons ? .on : .off
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        for button in [detailsButton, iconsButton] {
            button.setButtonType(.pushOnPushOff)
            button.image = button.image?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        }
        [label, spinner, detailsButton, iconsButton].forEach(addSubview)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            iconsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailsButton.trailingAnchor.constraint(equalTo: iconsButton.leadingAnchor, constant: -2),
            detailsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: detailsButton.leadingAnchor, constant: -40),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(itemCount: Int, selectedCount: Int, selectedSize: Int64?) {
        var text = Format.items(itemCount)
        if selectedCount > 0 {
            text += "   |   \(selectedCount == 1 ? "1 item" : "\(selectedCount) items") selected"
            if let selectedSize { text += "  \(Format.bytes(selectedSize))" }
        }
        label.stringValue = text
    }

    func setBusy(_ busy: Bool) {
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    @objc private func detailsPressed() { onViewModeSelected?(.details); viewMode = .details }
    @objc private func iconsPressed() { onViewModeSelected?(.largeIcons); viewMode = .largeIcons }
}
