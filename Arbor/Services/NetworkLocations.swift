import AppKit
import NetFS

/// A server the user mapped ("Map network drive"): shown on This Mac and optionally reconnected at launch.
struct NetworkLocation: Codable, Equatable {
    var address: String
    var reconnectAtLaunch: Bool

    var url: URL? { NetworkLocations.normalizedURL(address) }

    var displayName: String {
        guard let url else { return address }
        let share = url.path.split(separator: "/").last.map(String.init)
        if let host = url.host { return share.map { "\($0) (\(host))" } ?? host }
        return address
    }
}

/// Explorer's network drives for the Mac: connect to SMB / AFP / NFS / WebDAV / FTP servers with the
/// system's own sign-in sheet, and remember mapped servers.
enum NetworkLocations {
    static let schemes: Set<String> = ["smb", "cifs", "afp", "nfs", "ftp", "http", "https", "webdav", "vnc"]
    private static let storageKey = "NetworkLocations"
    private static let recentKey = "RecentServers"

    /// Accepts `smb://nas/share`, `\\nas\share` (Windows style) and bare `nas/share` (assumed SMB).
    static func normalizedURL(_ text: String) -> URL? {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        if address.hasPrefix("\\\\") {
            address = "smb://" + address.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
        } else if !address.contains("://") {
            address = "smb://" + address
        }
        guard let url = URL(string: address.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? address),
              let scheme = url.scheme?.lowercased(), schemes.contains(scheme), url.host != nil else { return nil }
        return url
    }

    /// Network URLs Arbor can mount itself (http/https/vnc go to the browser or Screen Sharing).
    static func isMountable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["smb", "cifs", "afp", "nfs", "ftp", "webdav"].contains(scheme)
    }

    // MARK: Saved locations

    static var saved: [NetworkLocation] {
        get {
            guard let data = UserDefaults.standard.data(forKey: storageKey),
                  let list = try? JSONDecoder().decode([NetworkLocation].self, from: data) else { return [] }
            return list
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: storageKey)
            NotificationCenter.default.post(name: .arborVolumesChanged, object: nil)
        }
    }

    static func save(_ location: NetworkLocation) {
        var list = saved.filter { $0.address.lowercased() != location.address.lowercased() }
        list.append(location)
        saved = list
    }

    static func forget(_ address: String) {
        saved = saved.filter { $0.address.lowercased() != address.lowercased() }
    }

    static var recentServers: [String] {
        get { UserDefaults.standard.stringArray(forKey: recentKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(10)), forKey: recentKey) }
    }

    // MARK: Mounting

    /// The mount point of an already-connected share, if any.
    static func mountedURL(for url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }
        let share = url.path.split(separator: "/").first.map { String($0).lowercased() }
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey]
        for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? [] {
            guard let remote = (try? volume.resourceValues(forKeys: Set(keys)))?.volumeURLForRemounting,
                  remote.host?.lowercased() == host else { continue }
            let remoteShare = remote.path.split(separator: "/").first.map { String($0).lowercased() }
            if share == nil || remoteShare == share { return volume.normalizedFolder }
        }
        return nil
    }

    /// Mounts the share (macOS asks for a name and password if needed) and calls back with the mount point.
    static func connect(_ url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        if let mounted = mountedURL(for: url) { return completion(.success(mounted)) }
        var request: AsyncRequestID?
        let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, nil, nil, &request, DispatchQueue.main) { status, _, mountpoints in
            let points = (mountpoints as? [String]) ?? []
            if status == 0, let first = points.first {
                NotificationCenter.default.post(name: .arborVolumesChanged, object: nil)
                completion(.success(URL(fileURLWithPath: first, isDirectory: true).normalizedFolder))
            } else if status == Int32(ECANCELED) || status == Int32(userCanceledErr) {
                completion(.failure(CocoaError(.userCancelled)))
            } else {
                let message = String(localized: "Arbor couldn't connect to “\(url.absoluteString)”.")
                completion(.failure(NSError(domain: NSPOSIXErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])))
            }
        }
        if status != 0 {
            completion(.failure(NSError(domain: NSPOSIXErrorDomain, code: Int(status))))
        }
    }

    /// "Reconnect at sign-in": mounts mapped servers in the background when Arbor starts.
    static func reconnectSaved() {
        for location in saved where location.reconnectAtLaunch {
            guard let url = location.url, mountedURL(for: url) == nil else { continue }
            connect(url) { _ in }
        }
    }
}

/// Explorer's "Map network drive" / Finder's "Connect to Server" dialog.
enum ConnectToServerDialog {
    struct Answer {
        let url: URL
        let remember: Bool
        let reconnect: Bool
    }

    static func run(prefill: String? = nil, mapping: Bool) -> Answer? {
        let alert = NSAlert()
        alert.messageText = mapping ? String(localized: "Map network drive") : String(localized: "Connect to Server")
        alert.informativeText = String(localized: "Type a server address, for example smb://nas/Share or \\\\nas\\Share.")
        alert.addButton(withTitle: String(localized: "Connect"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        field.addItems(withObjectValues: NetworkLocations.recentServers)
        field.stringValue = prefill ?? NetworkLocations.recentServers.first ?? "smb://"
        field.completes = true
        let remember = NSButton(checkboxWithTitle: String(localized: "Show on This Mac"), target: nil, action: nil)
        remember.state = mapping ? .on : .off
        let reconnect = NSButton(checkboxWithTitle: String(localized: "Reconnect when Arbor starts"), target: nil, action: nil)
        reconnect.state = mapping ? .on : .off
        let stack = NSStackView(views: [field, remember, reconnect])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 84)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field

        while alert.runModal() == .alertFirstButtonReturn {
            guard let url = NetworkLocations.normalizedURL(field.stringValue) else {
                let problem = NSAlert()
                problem.messageText = String(localized: "That isn't a server address Arbor understands.")
                problem.informativeText = String(localized: "Use smb://, afp://, nfs://, ftp:// or webdav://, or \\\\server\\share.")
                problem.runModal()
                continue
            }
            var recent = NetworkLocations.recentServers.filter { $0 != field.stringValue }
            recent.insert(field.stringValue, at: 0)
            NetworkLocations.recentServers = recent
            return Answer(url: url, remember: remember.state == .on, reconnect: reconnect.state == .on && remember.state == .on)
        }
        return nil
    }
}
