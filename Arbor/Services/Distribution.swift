import AppKit
#if canImport(Sparkle) && !APPSTORE
import Sparkle
#endif

/// The two ways Arbor ships: the notarized download (every feature, Sparkle updates) and the
/// sandboxed Mac App Store build (compiled with `APPSTORE`).
enum Edition {
    #if APPSTORE
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif

    /// The store build can't make itself the default folder viewer or update itself.
    static var canSetDefaultFolderViewer: Bool { !isAppStore }
}

// MARK: - Mac App Store: disk access

/// A sandboxed app can only see what the user hands it. Arbor asks once for a disk (normally the
/// startup disk, which covers everything) and keeps that access in a security-scoped bookmark.
enum SandboxAccess {
    private static let bookmarksKey = "SandboxBookmarks"
    private static var active: [URL] = []

    static var grantedLocations: [URL] { active }

    /// Restores access granted in earlier sessions. Call at launch.
    static func restore() {
        guard Edition.isAppStore else { return }
        let stored = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] ?? []
        var refreshed: [Data] = []
        for data in stored {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { continue }
            active.append(url)
            refreshed.append(stale ? ((try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? data) : data)
        }
        UserDefaults.standard.set(refreshed, forKey: bookmarksKey)
    }

    static var needsAccess: Bool { Edition.isAppStore && active.isEmpty }

    /// Shows the explanation and an open panel pointed at the startup disk. Returns true if access was granted.
    @discardableResult
    static func requestAccess(suggesting folder: URL = URL(fileURLWithPath: "/")) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = String(localized: "Grant Access")
        panel.message = String(localized: "Arbor is sandboxed in the App Store version. Choose your startup disk (Macintosh HD) to let Arbor show all your files, or choose a single folder.")
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil),
              url.startAccessingSecurityScopedResource() else { return false }
        active.append(url)
        var stored = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] ?? []
        stored.append(data)
        UserDefaults.standard.set(stored, forKey: bookmarksKey)
        NotificationCenter.default.post(name: .arborPreferencesChanged, object: nil)
        return true
    }
}

// MARK: - Download: Sparkle updates

/// Sparkle runs only in the download build, and only when the build has an update-signing public key
/// (`SPARKLE_PUBLIC_KEY`), so unsigned local builds never nag about updates.
final class Updater: NSObject {
    static let shared = Updater()

    #if canImport(Sparkle) && !APPSTORE
    private var controller: SPUStandardUpdaterController?
    #endif

    var isAvailable: Bool {
        #if canImport(Sparkle) && !APPSTORE
        return controller != nil
        #else
        return false
        #endif
    }

    func start() {
        #if canImport(Sparkle) && !APPSTORE
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
    }

    @objc func checkForUpdates(_ sender: Any?) {
        #if canImport(Sparkle) && !APPSTORE
        controller?.checkForUpdates(sender)
        #endif
    }
}
