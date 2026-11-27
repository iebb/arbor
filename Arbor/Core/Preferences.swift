import AppKit

extension Notification.Name {
    static let arborPreferencesChanged = Notification.Name("ArborPreferencesChanged")
    static let arborPinsChanged = Notification.Name("ArborPinsChanged")
    /// userInfo["folders"]: [URL] — folders whose contents changed because of an Arbor operation.
    static let arborFoldersChanged = Notification.Name("ArborFoldersChanged")
    static let arborClipboardChanged = Notification.Name("ArborClipboardChanged")
    static let arborVolumesChanged = Notification.Name("ArborVolumesChanged")
    static let arborRecentsChanged = Notification.Name("ArborRecentsChanged")
}

enum StartLocation: String, CaseIterable {
    case home, thisMac, iCloudDrive, desktop, documents, downloads

    var title: String {
        switch self {
        case .home: return String(localized: "Home")
        case .thisMac: return String(localized: "This Mac")
        case .iCloudDrive: return String(localized: "iCloud Drive")
        case .desktop: return String(localized: "Desktop")
        case .documents: return String(localized: "Documents")
        case .downloads: return String(localized: "Downloads")
        }
    }

    /// The choices Folder Options offers (iCloud Drive only when it's set up).
    static var available: [StartLocation] {
        allCases.filter { $0 != .iCloudDrive || FileManager.default.fileExists(atPath: Self.iCloudURL.path) }
    }

    static var iCloudURL: URL {
        FileManager.default.realHomeDirectory
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    var location: Location {
        func user(_ dir: FileManager.SearchPathDirectory) -> Location {
            guard let url = FileManager.default.userFolderURL(dir) else { return .home }
            return .folder(url.normalizedFolder)
        }
        switch self {
        case .home: return .home
        case .thisMac: return .thisMac
        case .iCloudDrive:
            return FileManager.default.fileExists(atPath: Self.iCloudURL.path) ? .folder(Self.iCloudURL.normalizedFolder) : .home
        case .desktop: return user(.desktopDirectory)
        case .documents: return user(.documentDirectory)
        case .downloads: return user(.downloadsDirectory)
        }
    }
}

/// Every on/off setting, mostly Explorer's Folder Options. The raw value is the UserDefaults key.
enum FolderOption: String, CaseIterable {
    // General
    case openFoldersInNewWindow = "OpenFoldersInNewWindow"
    case singleClickToOpen = "SingleClickToOpen"
    case underlineOnlyOnHover = "UnderlineOnlyOnHover"
    case showRecentFiles = "ShowRecentFiles"
    case showFrequentFolders = "ShowFrequentFolders"
    // View › Files and Folders
    case alwaysShowIcons = "AlwaysShowIcons"
    case fileIconOnThumbnails = "FileIconOnThumbnails"
    case folderTipSize = "FolderTipSize"
    case fullPathInTitleBar = "FullPathInTitleBar"
    case showHidden = "ShowHiddenItems"
    case hideEmptyDrives = "HideEmptyDrives"
    case showExtensions = "ShowFileNameExtensions"
    case hideProtectedSystemFiles = "HideProtectedSystemFiles"
    case restoreWindowsAtLaunch = "RestoreWindowsAtLaunch"
    case popUpDescriptions = "PopUpDescriptions"
    case previewHandlers = "PreviewHandlers"
    case showStatusBar = "ShowStatusBar"
    case itemCheckBoxes = "ItemCheckBoxes"
    case backspaceGoesBack = "BackspaceGoesBack"
    case typeIntoSearchBox = "TypeIntoSearchBox"
    // View › Navigation pane
    case expandToOpenFolder = "ExpandToOpenFolder"
    case showThisMac = "ShowThisMacInTree"
    // Search
    case searchSystemDirectories = "SearchSystemDirectories"
    case searchCompressedFiles = "SearchCompressedFiles"
    case searchFileContents = "SearchFileContents"
    // View menu (not in the dialog)
    case compactView = "CompactView"
    case showNavigationPane = "ShowNavigationPane"
    case showPreviewPane = "ShowPreviewPane"

    var defaultValue: Bool {
        switch self {
        case .underlineOnlyOnHover, .showRecentFiles, .showFrequentFolders, .fileIconOnThumbnails, .folderTipSize,
             .hideEmptyDrives, .hideProtectedSystemFiles, .popUpDescriptions, .previewHandlers, .showStatusBar,
             .backspaceGoesBack, .expandToOpenFolder, .showThisMac, .searchSystemDirectories, .showNavigationPane:
            return true
        default:
            return false
        }
    }

    /// Pane visibility is window layout, not a setting other views react to.
    var postsChange: Bool { self != .showNavigationPane && self != .showPreviewPane }

    static let generalTab: [FolderOption] = [.openFoldersInNewWindow, .singleClickToOpen, .underlineOnlyOnHover, .showRecentFiles, .showFrequentFolders]
    static let viewTab: [FolderOption] = [
        .alwaysShowIcons, .fileIconOnThumbnails, .folderTipSize, .fullPathInTitleBar, .showHidden, .hideEmptyDrives,
        .showExtensions, .hideProtectedSystemFiles, .restoreWindowsAtLaunch, .popUpDescriptions, .previewHandlers,
        .showStatusBar, .itemCheckBoxes, .backspaceGoesBack, .typeIntoSearchBox, .expandToOpenFolder, .showThisMac,
    ]
    static let searchTab: [FolderOption] = [.searchSystemDirectories, .searchCompressedFiles, .searchFileContents]
}

/// App-wide settings, the equivalent of Explorer's "Folder Options".
final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard
    private static let startLocationKey = "StartLocation"
    private static let pinnedKey = "PinnedFolders"
    private static let defaultViewModeKey = "DefaultViewMode"
    private static let defaultSortKeyKey = "DefaultSortKey"
    private static let defaultSortAscendingKey = "DefaultSortAscending"

    private init() {
        var registered: [String: Any] = [
            Self.startLocationKey: StartLocation.home.rawValue,
            Self.defaultViewModeKey: ViewMode.details.rawValue,
            Self.defaultSortKeyKey: SortKey.name.rawValue,
            Self.defaultSortAscendingKey: true,
        ]
        for option in FolderOption.allCases { registered[option.rawValue] = option.defaultValue }
        defaults.register(defaults: registered)
    }

    private func changed() {
        NotificationCenter.default.post(name: .arborPreferencesChanged, object: self)
    }

    subscript(option: FolderOption) -> Bool {
        get { defaults.bool(forKey: option.rawValue) }
        set {
            guard newValue != self[option] else { return }
            defaults.set(newValue, forKey: option.rawValue)
            if option.postsChange { changed() }
        }
    }

    /// Applies several settings at once with a single change notification (Folder Options' Apply/OK).
    func apply(_ values: [FolderOption: Bool], startLocation newStart: StartLocation? = nil) {
        var didChange = false
        for (option, value) in values where self[option] != value {
            defaults.set(value, forKey: option.rawValue)
            didChange = didChange || option.postsChange
        }
        if let newStart, newStart != startLocation {
            defaults.set(newStart.rawValue, forKey: Self.startLocationKey)
            didChange = true
        }
        if didChange { changed() }
    }

    func toggle(_ option: FolderOption) { self[option].toggle() }

    // Shorthand for the settings read most often.
    var showHidden: Bool { get { self[.showHidden] } set { self[.showHidden] = newValue } }
    var showExtensions: Bool { get { self[.showExtensions] } set { self[.showExtensions] = newValue } }
    var expandToOpenFolder: Bool { self[.expandToOpenFolder] }
    var backspaceGoesBack: Bool { self[.backspaceGoesBack] }
    var showPreviewPane: Bool { get { self[.showPreviewPane] } set { self[.showPreviewPane] = newValue } }
    var showNavigationPane: Bool { get { self[.showNavigationPane] } set { self[.showNavigationPane] = newValue } }

    /// The system-wide shortcut that opens a new Arbor window (Explorer's Win+E). Off by default,
    /// because a global shortcut takes the key away from every other app.
    var hotKey: HotKeyChoice {
        get { HotKeyChoice(rawValue: defaults.string(forKey: "GlobalHotKey") ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "GlobalHotKey"); changed() }
    }

    var startLocation: StartLocation {
        get { StartLocation(rawValue: defaults.string(forKey: Self.startLocationKey) ?? "") ?? .home }
        set { defaults.set(newValue.rawValue, forKey: Self.startLocationKey); changed() }
    }

    var defaultViewSettings: FolderViewSettings {
        get {
            let mode = ViewMode(rawValue: defaults.string(forKey: Self.defaultViewModeKey) ?? "") ?? .details
            let key = SortKey(rawValue: defaults.string(forKey: Self.defaultSortKeyKey) ?? "") ?? .name
            return FolderViewSettings(viewMode: mode, sort: SortOrder(key: key, ascending: defaults.bool(forKey: Self.defaultSortAscendingKey)))
        }
        set {
            defaults.set(newValue.viewMode.rawValue, forKey: Self.defaultViewModeKey)
            defaults.set(newValue.sort.key.rawValue, forKey: Self.defaultSortKeyKey)
            defaults.set(newValue.sort.ascending, forKey: Self.defaultSortAscendingKey)
        }
    }

    // MARK: Quick access pins

    var pinnedFolders: [URL] {
        get {
            guard let paths = defaults.stringArray(forKey: Self.pinnedKey) else { return Preferences.defaultPins }
            return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        set {
            defaults.set(newValue.map(\.pathKey), forKey: Self.pinnedKey)
            NotificationCenter.default.post(name: .arborPinsChanged, object: self)
        }
    }

    static var defaultPins: [URL] {
        let dirs: [FileManager.SearchPathDirectory] = [.desktopDirectory, .downloadsDirectory, .documentDirectory, .picturesDirectory, .musicDirectory, .moviesDirectory]
        return dirs.compactMap { FileManager.default.userFolderURL($0)?.normalizedFolder }
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

/// Explorer's history for the Privacy options: frequently used folders and recently used files.
final class RecentItems {
    static let shared = RecentItems()
    private let foldersKey = "FrequentFolderCounts"
    private let filesKey = "RecentFiles"
    private var folderCounts: [String: Int]
    private var files: [String]

    private init() {
        folderCounts = UserDefaults.standard.dictionary(forKey: foldersKey) as? [String: Int] ?? [:]
        files = UserDefaults.standard.stringArray(forKey: filesKey) ?? []
    }

    func recordFolderVisit(_ url: URL) {
        let before = frequentFolders()
        folderCounts[url.pathKey, default: 0] += 1
        if folderCounts.count > 500 {
            // Forget the least-used folders.
            for (key, _) in folderCounts.sorted(by: { $0.value < $1.value }).prefix(100) { folderCounts.removeValue(forKey: key) }
        }
        UserDefaults.standard.set(folderCounts, forKey: foldersKey)
        if frequentFolders() != before { NotificationCenter.default.post(name: .arborRecentsChanged, object: self) }
    }

    func recordFileOpen(_ url: URL) {
        files.removeAll { $0 == url.pathKey }
        files.insert(url.pathKey, at: 0)
        files = Array(files.prefix(20))
        UserDefaults.standard.set(files, forKey: filesKey)
        NotificationCenter.default.post(name: .arborRecentsChanged, object: self)
    }

    /// Folders visited at least three times, most used first — excluding Home and pinned folders.
    func frequentFolders(limit: Int = 6) -> [URL] {
        let home = FileManager.default.realHomeDirectory.pathKey
        return folderCounts
            .filter { $0.value >= 3 && $0.key != home }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { URL(fileURLWithPath: $0.key, isDirectory: true) }
            .filter { !Preferences.shared.isPinned($0) && FileManager.default.fileExists(atPath: $0.path) }
            .prefix(limit)
            .map { $0 }
    }

    func recentFiles(limit: Int = 15) -> [URL] {
        files.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(limit).map { $0 }
    }

    /// "Clear File Explorer history".
    func clear() {
        folderCounts = [:]
        files = []
        UserDefaults.standard.removeObject(forKey: foldersKey)
        UserDefaults.standard.removeObject(forKey: filesKey)
        NotificationCenter.default.post(name: .arborRecentsChanged, object: self)
    }
}
