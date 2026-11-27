import Foundation

/// Explorer's layouts (View ▸ …), in Explorer's Ctrl+Shift+1…7 order.
enum ViewMode: String, CaseIterable {
    case extraLargeIcons, largeIcons, mediumIcons, smallIcons, list, details, tiles

    var title: String {
        switch self {
        case .extraLargeIcons: return "Extra large icons"
        case .largeIcons: return "Large icons"
        case .mediumIcons: return "Medium icons"
        case .smallIcons: return "Small icons"
        case .list: return "List"
        case .details: return "Details"
        case .tiles: return "Tiles"
        }
    }

    var symbolName: String {
        switch self {
        case .extraLargeIcons: return "square.grid.2x2"
        case .largeIcons: return "square.grid.3x2"
        case .mediumIcons: return "square.grid.3x3"
        case .smallIcons: return "square.grid.4x3.fill"
        case .list: return "list.bullet"
        case .details: return "list.bullet.rectangle"
        case .tiles: return "rectangle.grid.2x2"
        }
    }

    /// 1-based index used by the ⌃⇧1…7 shortcuts.
    var shortcutNumber: Int { (ViewMode.allCases.firstIndex(of: self) ?? 0) + 1 }
}

enum SortKey: String, CaseIterable {
    case name, dateModified, type, size, dateCreated

    var title: String {
        switch self {
        case .name: return "Name"
        case .dateModified: return "Date modified"
        case .type: return "Type"
        case .size: return "Size"
        case .dateCreated: return "Date created"
        }
    }
}

struct SortOrder: Equatable {
    var key: SortKey = .name
    var ascending: Bool = true
}

/// Per-folder view memory (Explorer remembers layout and sort for each folder).
struct FolderViewSettings: Equatable {
    var viewMode: ViewMode
    var sort: SortOrder

    var encoded: String { "\(viewMode.rawValue)|\(sort.key.rawValue)|\(sort.ascending ? 1 : 0)" }

    init(viewMode: ViewMode, sort: SortOrder) {
        self.viewMode = viewMode
        self.sort = sort
    }

    init?(encoded: String) {
        let parts = encoded.split(separator: "|").map(String.init)
        guard parts.count == 3, let mode = ViewMode(rawValue: parts[0]), let key = SortKey(rawValue: parts[1]) else { return nil }
        self.init(viewMode: mode, sort: SortOrder(key: key, ascending: parts[2] == "1"))
    }
}

extension FileItem {
    /// Explorer ordering: folders are grouped before files when ascending (after them when descending),
    /// ties fall back to a natural ("file2" < "file10") name comparison.
    static func increasingOrder(_ a: FileItem, _ b: FileItem, key: SortKey) -> Bool {
        if a.isFolder != b.isFolder { return a.isFolder }
        let result: ComparisonResult
        switch key {
        case .name: result = a.name.localizedStandardCompare(b.name)
        case .dateModified: result = (a.modified ?? .distantPast).compare(b.modified ?? .distantPast)
        case .dateCreated: result = (a.created ?? .distantPast).compare(b.created ?? .distantPast)
        case .type: result = a.kind.localizedStandardCompare(b.kind)
        case .size:
            let lhs = a.size ?? -1, rhs = b.size ?? -1
            result = lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        }
        if result == .orderedSame, key != .name {
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return result == .orderedAscending
    }
}

extension Array where Element == FileItem {
    func sorted(by order: SortOrder) -> [FileItem] {
        order.ascending
            ? sorted { FileItem.increasingOrder($0, $1, key: order.key) }
            : sorted { FileItem.increasingOrder($1, $0, key: order.key) }
    }
}
