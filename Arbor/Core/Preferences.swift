import AppKit

extension Notification.Name {
    static let arborPreferencesChanged = Notification.Name("ArborPreferencesChanged")
    static let arborPinsChanged = Notification.Name("ArborPinsChanged")
    /// userInfo["folders"]: [URL] — folders whose contents changed because of an Arbor operation.
    static let arborFoldersChanged = Notification.Name("ArborFoldersChanged")
    static let arborClipboardChanged = Notification.Name("ArborClipboardChanged")
    static let arborVolumesChanged = Notification.Name("ArborVolumesChanged")
}

enum StartLocation: String, CaseIterable {
    case home, thisMac, desktop, documents, downloads

    var title: String {
        switch self {
        case .home: return "Home"
        case .thisMac: return "This Mac"
        case .desktop: return "Desktop"
        case .documents: return "Documents"
        case .downloads: return "Downloads"
        }
    }

    var location: Location {
        func user(_ dir: FileManager.SearchPathDirectory) -> Location {
            guard let url = FileManager.default.urls(for: dir, in: .userDomainMask).first else { return .home }
            return .folder(url.normalizedFolder)
        }
        switch self {
        case .home: return .home
        case .thisMac: return .thisMac
        case .desktop: return user(.desktopDirectory)
        case .documents: return user(.documentDirectory)
        case .downloads: return user(.downloadsDirectory)
        }
    }
}

/// App-wide settings, the equivalent of Explorer's "Folder Options".
final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let showHidden = "ShowHiddenItems"
        static let showExtensions = "ShowFileNameExtensions"
        static let expandToOpenFolder = "ExpandToOpenFolder"
        static let backspaceGoesBack = "BackspaceGoesBack"
        static let startLocation = "StartLocation"
        static let showPreviewPane = "ShowPreviewPane"
        static let showNavigationPane = "ShowNavigationPane"
        static let defaultViewMode = "DefaultViewMode"
        static let defaultSortKey = "DefaultSortKey"
        static let defaultSortAscending = "DefaultSortAscending"
        static let pinned = "PinnedFolders"
    }

    private init() {
        defaults.register(defaults: [
            Key.showHidden: false,
            Key.showExtensions: false,
            Key.expandToOpenFolder: true,
            Key.backspaceGoesBack: true,
            Key.startLocation: StartLocation.home.rawValue,
            Key.showPreviewPane: false,
            Key.showNavigationPane: true,
            Key.defaultViewMode: ViewMode.details.rawValue,
            Key.defaultSortKey: SortKey.name.rawValue,
            Key.defaultSortAscending: true,
        ])
    }

    private func changed() {
        NotificationCenter.default.post(name: .arborPreferencesChanged, object: self)
    }

    var showHidden: Bool {
        get { defaults.bool(forKey: Key.showHidden) }
        set { defaults.set(newValue, forKey: Key.showHidden); changed() }
    }

    var showExtensions: Bool {
        get { defaults.bool(forKey: Key.showExtensions) }
        set { defaults.set(newValue, forKey: Key.showExtensions); changed() }
    }

    var expandToOpenFolder: Bool {
        get { defaults.bool(forKey: Key.expandToOpenFolder) }
        set { defaults.set(newValue, forKey: Key.expandToOpenFolder); changed() }
    }

    /// Explorer: Backspace goes back. Off: Backspace moves the selection to the Trash (Finder habit).
    var backspaceGoesBack: Bool {
        get { defaults.bool(forKey: Key.backspaceGoesBack) }
        set { defaults.set(newValue, forKey: Key.backspaceGoesBack); changed() }
    }

    var startLocation: StartLocation {
        get { StartLocation(rawValue: defaults.string(forKey: Key.startLocation) ?? "") ?? .home }
        set { defaults.set(newValue.rawValue, forKey: Key.startLocation); changed() }
    }

    var showPreviewPane: Bool {
        get { defaults.bool(forKey: Key.showPreviewPane) }
        set { defaults.set(newValue, forKey: Key.showPreviewPane) }
    }

    var showNavigationPane: Bool {
        get { defaults.bool(forKey: Key.showNavigationPane) }
        set { defaults.set(newValue, forKey: Key.showNavigationPane) }
    }

    var defaultViewSettings: FolderViewSettings {
        get {
            let mode = ViewMode(rawValue: defaults.string(forKey: Key.defaultViewMode) ?? "") ?? .details
            let key = SortKey(rawValue: defaults.string(forKey: Key.defaultSortKey) ?? "") ?? .name
            return FolderViewSettings(viewMode: mode, sort: SortOrder(key: key, ascending: defaults.bool(forKey: Key.defaultSortAscending)))
        }
        set {
            defaults.set(newValue.viewMode.rawValue, forKey: Key.defaultViewMode)
            defaults.set(newValue.sort.key.rawValue, forKey: Key.defaultSortKey)
            defaults.set(newValue.sort.ascending, forKey: Key.defaultSortAscending)
        }
    }

    // MARK: Quick access pins

    var pinnedFolders: [URL] {
        get {
            guard let paths = defaults.stringArray(forKey: Key.pinned) else { return Preferences.defaultPins }
            return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        set {
            defaults.set(newValue.map(\.pathKey), forKey: Key.pinned)
            NotificationCenter.default.post(name: .arborPinsChanged, object: self)
        }
    }

    static var defaultPins: [URL] {
        let dirs: [FileManager.SearchPathDirectory] = [.desktopDirectory, .downloadsDirectory, .documentDirectory, .picturesDirectory, .musicDirectory, .moviesDirectory]
        return dirs.compactMap { FileManager.default.urls(for: $0, in: .userDomainMask).first?.normalizedFolder }
    }

    func isPinned(_ url: URL) -> Bool { pinnedFolders.contains { $0.isSameItem(as: url) } }

    func pin(_ url: URL) {
        guard !isPinned(url) else { return }
        pinnedFolders.append(url.normalizedFolder)
    }

    func unpin(_ url: URL) {
        pinnedFolders.removeAll { $0.isSameItem(as: url) }
    }
}

/// Remembers the layout and sort order of each folder, like Explorer does.
final class FolderViewStore {
    static let shared = FolderViewStore()
    private let storageKey = "FolderViewSettings"
    private let maxEntries = 2000
    private var entries: [String: String]

    private init() {
        entries = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }

    func settings(for location: Location) -> FolderViewSettings {
        guard let key = key(for: location) else { return Preferences.shared.defaultViewSettings }
        if let stored = entries[key], let settings = FolderViewSettings(encoded: stored) { return settings }
        if location.isSearch {
            return FolderViewSettings(viewMode: .details, sort: Preferences.shared.defaultViewSettings.sort)
        }
        return Preferences.shared.defaultViewSettings
    }

    func save(_ settings: FolderViewSettings, for location: Location) {
        guard let key = key(for: location) else { return }
        entries[key] = settings.encoded
        if entries.count > maxEntries, let victim = entries.keys.first(where: { $0 != key }) {
            entries.removeValue(forKey: victim)
        }
        UserDefaults.standard.set(entries, forKey: storageKey)
    }

    /// "Reset Folders": forget every per-folder layout.
    func reset() {
        entries = [:]
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// "Apply to Folders": make these settings the default and forget per-folder overrides.
    func applyToAllFolders(_ settings: FolderViewSettings) {
        Preferences.shared.defaultViewSettings = settings
        reset()
    }

    private func key(for location: Location) -> String? {
        switch location {
        case .thisMac: return nil
        case .folder(let url): return url.pathKey
        case .search: return "search:"
        }
    }
}
