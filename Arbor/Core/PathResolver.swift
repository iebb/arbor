import Foundation

/// Interprets what the user typed in the address bar.
enum PathResolver {
    enum Resolution: Equatable {
        case location(Location)
        case file(URL)
        case web(URL)
        case notFound(String)
    }

    typealias ExistsCheck = (String) -> (exists: Bool, isDirectory: Bool)

    static let fileSystemCheck: ExistsCheck = { path in
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return (exists, isDir.boolValue)
    }

    static func resolve(_ input: String, relativeTo base: URL?, check: ExistsCheck = fileSystemCheck) -> Resolution {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        guard !text.isEmpty else { return .notFound(input) }

        let lowered = text.lowercased()
        if ["this mac", "this pc", "computer", String(localized: "This Mac").lowercased()].contains(lowered) { return .location(.thisMac) }

        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme.count > 1 {
            if scheme == "file" {
                text = url.path
            } else if ["http", "https", "ftp", "smb", "cifs", "afp", "nfs", "webdav", "vnc", "mailto"].contains(scheme) {
                return .web(url)
            }
        }

        var path = (text as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            guard let base else { return .notFound(input) }
            path = base.appendingPathComponent(path).path
        }
        path = (path as NSString).standardizingPath

        let result = check(path)
        guard result.exists else { return .notFound(input) }
        let url = URL(fileURLWithPath: path, isDirectory: result.isDirectory)
        return result.isDirectory ? .location(.folder(url.normalizedFolder)) : .file(url)
    }
}
