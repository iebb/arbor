import AppKit

extension NSImage {
    /// A 16 pt copy for menus (never resize a shared cached image in place).
    var menuSized: NSImage {
        let copy = (self.copy() as? NSImage) ?? self
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    static func symbol(_ name: String, size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        guard let size else { return image }
        return image?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
}

extension NSTextField {
    static func label(_ text: String = "", size: CGFloat = NSFont.systemFontSize, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
}

/// A label that lets clicks fall through to whatever is underneath.
final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A flat toolbar button that highlights on hover, like Explorer's command bar.
final class HoverButton: NSButton {
    convenience init(symbol: String, title: String? = nil, toolTip: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.image = NSImage.symbol(symbol, size: 14)
        self.title = title ?? ""
        self.imagePosition = title == nil ? .imageOnly : .imageLeading
        self.imageHugsTitle = true
        self.bezelStyle = .recessed
        self.showsBorderOnlyWhileMouseInside = true
        self.setButtonType(.momentaryPushIn)
        self.toolTip = toolTip
        self.target = target
        self.action = action
        self.font = .systemFont(ofSize: 12.5)
        self.translatesAutoresizingMaskIntoConstraints = false
        if title == nil {
            widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        }
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    func popUp(_ menu: NSMenu) {
        let y = isFlipped ? bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: self)
    }
}

/// Explorer's 16 pt key codes we route by hand.
enum KeyCode {
    static let returnKey: UInt16 = 36
    static let enter: UInt16 = 76
    static let backspace: UInt16 = 51
    static let forwardDelete: UInt16 = 117
    static let space: UInt16 = 49
    static let escape: UInt16 = 53
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
    static let home: UInt16 = 115
    static let end: UInt16 = 119
    static let f2: UInt16 = 120
    static let f3: UInt16 = 99
    static let f4: UInt16 = 118
    static let f5: UInt16 = 96
    static let d: UInt16 = 2
    static let n: UInt16 = 45
    static let p: UInt16 = 35
    /// Number row 1…7.
    static let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26]
}

func functionKey(_ code: Int) -> String {
    String(Character(UnicodeScalar(UInt16(code))!))
}

/// Shared drag-and-drop rules: same drive moves, other drive copies; ⌥ forces copy, ⌘ forces move.
enum DragDrop {
    static func fileURLs(from info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    static func operation(for info: NSDraggingInfo, destination: URL) -> NSDragOperation {
        let urls = fileURLs(from: info)
        guard !urls.isEmpty else { return [] }
        for url in urls where url.isSameItem(as: destination) || destination.isDescendant(of: url) {
            return []
        }
        let mask = info.draggingSourceOperationMask
        let allInPlace = urls.allSatisfy { $0.parentFolder.isSameItem(as: destination) }
        if mask == .copy { return .copy }
        if allInPlace { return [] }
        if mask == .generic { return .move }
        if sameVolume(urls[0], destination), mask.contains(.move) || mask.contains(.generic) { return .move }
        if mask.contains(.copy) { return .copy }
        return mask.contains(.move) ? .move : []
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let x = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject,
              let y = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject else { return false }
        return x.isEqual(y)
    }
}
