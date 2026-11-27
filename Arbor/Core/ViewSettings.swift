import Foundation

/// Explorer's layouts (View ▸ …), in Explorer's Ctrl+Shift+1…8 order.
enum ViewMode: String, CaseIterable {
    case extraLargeIcons, largeIcons, mediumIcons, smallIcons, list, details, tiles, content

    var title: String {
        switch self {
        case .extraLargeIcons: return String(localized: "Extra large icons")
        case .largeIcons: return String(localized: "Large icons")
        case .mediumIcons: return String(localized: "Medium icons")
        case .smallIcons: return String(localized: "Small icons")
        case .list: return String(localized: "List")
        case .details: return String(localized: "Details")
        case .tiles: return String(localized: "Tiles")
        case .content: return String(localized: "Content")
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
        case .content: return "list.bullet.below.rectangle"
        }
    }

    /// 1-based index used by the ⌃⇧1…8 shortcuts.
    var shortcutNumber: Int { (ViewMode.allCases.firstIndex(of: self) ?? 0) + 1 }
}

enum SortKey: String, CaseIterable {
    case name, dateModified, type, size, dateCreated

    var title: String {
        switch self {
        case .name: return String(localized: "Name")
        case .dateModified: return String(localized: "Date modified")
        case .type: return String(localized: "Type")
        case .size: return String(localized: "Size")
        case .dateCreated: return String(localized: "Date created")
        }
    }
}

struct SortOrder: Equatable {
    var key: SortKey = .name
    var ascending: Bool = true
}

/// Per-folder view memory (Explorer remembers layout, sort and grouping for each folder).
struct FolderViewSettings: Equatable {
    var viewMode: ViewMode
    var sort: SortOrder
    var groupBy: GroupKey = .none

    var encoded: String { "\(viewMode.rawValue)|\(sort.key.rawValue)|\(sort.ascending ? 1 : 0)|\(groupBy.rawValue)" }

    init(viewMode: ViewMode, sort: SortOrder, groupBy: GroupKey = .none) {
        self.viewMode = viewMode
        self.sort = sort
        self.groupBy = groupBy
    }

    /// Reads "mode|key|ascending" (older versions) or "mode|key|ascending|group".
    init?(encoded: String) {
        let parts = encoded.split(separator: "|").map(String.init)
        guard parts.count >= 3, let mode = ViewMode(rawValue: parts[0]), let key = SortKey(rawValue: parts[1]) else { return nil }
        let group = parts.count > 3 ? GroupKey(rawValue: parts[3]) ?? .none : .none
        self.init(viewMode: mode, sort: SortOrder(key: key, ascending: parts[2] == "1"), groupBy: group)
    }
}

/// Explorer's Group by.
enum GroupKey: String, CaseIterable {
    case none, name, dateModified, type, size

    var title: String {
        switch self {
        case .none: return String(localized: "(None)")
        case .name: return String(localized: "Name")
        case .dateModified: return String(localized: "Date modified")
        case .type: return String(localized: "Type")
        case .size: return String(localized: "Size")
        }
    }
}

struct ItemGroup: Equatable {
    let title: String
    let items: [FileItem]
}

/// Splits sorted items into Explorer's groups. Items keep their sort order inside each group.
enum FileGrouping {
    static func groups(_ items: [FileItem], by key: GroupKey, now: Date = Date(), calendar: Calendar = .current) -> [ItemGroup] {
        guard key != .none else { return [ItemGroup(title: "", items: items)] }
        var buckets: [String: (rank: Double, items: [FileItem])] = [:]
        var order: [String] = []
        for item in items {
            let (title, rank) = bucket(for: item, by: key, now: now, calendar: calendar)
            if buckets[title] == nil {
                buckets[title] = (rank, [])
                order.append(title)
            }
            buckets[title]?.items.append(item)
        }
        // Names and types read A→Z; dates newest first and sizes biggest first, as Explorer shows them.
        let sorted = order.sorted { a, b in
            let ra = buckets[a]!.rank, rb = buckets[b]!.rank
            if ra != rb { return ra < rb }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return sorted.map { ItemGroup(title: $0, items: buckets[$0]!.items) }
    }

    private static func bucket(for item: FileItem, by key: GroupKey, now: Date, calendar: Calendar) -> (String, Double) {
        switch key {
        case .none:
            return ("", 0)
        case .name:
            guard let first = item.name.uppercased().unicodeScalars.first else { return (String(localized: "Other"), 9) }
            switch first {
            case "0"..."9": return ("0 – 9", 0)
            case "A"..."H": return ("A – H", 1)
            case "I"..."P": return ("I – P", 2)
            case "Q"..."Z": return ("Q – Z", 3)
            default: return (String(localized: "Other"), 9)
            }
        case .type:
            // Rank 0 for everything: groups are ordered by title. Folders still come first.
            return (item.kind, item.isFolder ? -1 : 0)
        case .size:
            guard !item.isFolder, let size = item.size else { return (String(localized: "Unspecified"), 99) }
            let kb: Int64 = 1024, mb = kb * 1024, gb = mb * 1024
            switch size {
            case 0: return (String(localized: "Empty (0 KB)"), 7)
            case ..<(16 * kb): return (String(localized: "Tiny (0 – 16 KB)"), 6)
            case ..<mb: return (String(localized: "Small (16 KB – 1 MB)"), 5)
            case ..<(128 * mb): return (String(localized: "Medium (1 – 128 MB)"), 4)
            case ..<gb: return (String(localized: "Large (128 MB – 1 GB)"), 3)
            case ..<(4 * gb): return (String(localized: "Huge (1 – 4 GB)"), 2)
            default: return (String(localized: "Gigantic (> 4 GB)"), 1)
            }
        case .dateModified:
            guard let date = item.modified else { return (String(localized: "Unspecified"), 99) }
            let today = calendar.startOfDay(for: now)
            let day = calendar.startOfDay(for: date)
            let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            if daysAgo <= 0 { return (String(localized: "Today"), 0) }
            if daysAgo == 1 { return (String(localized: "Yesterday"), 1) }
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)
            if let thisWeek, date >= thisWeek.start { return (String(localized: "Earlier this week"), 2) }
            if let thisWeek, let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek.start), date >= lastWeek {
                return (String(localized: "Last week"), 3)
            }
            let thisMonth = calendar.dateInterval(of: .month, for: now)
            if let thisMonth, date >= thisMonth.start { return (String(localized: "Earlier this month"), 4) }
            if let thisMonth, let lastMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth.start), date >= lastMonth {
                return (String(localized: "Last month"), 5)
            }
            if let thisYear = calendar.dateInterval(of: .year, for: now), date >= thisYear.start {
                return (String(localized: "Earlier this year"), 6)
            }
            return (String(localized: "A long time ago"), 7)
        }
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
