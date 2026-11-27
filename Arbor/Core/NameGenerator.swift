import Foundation

/// Explorer's naming rules for new and duplicated items.
enum NameGenerator {
    /// Splits "report.txt" into ("report", "txt"). Folders and dotfiles have no extension.
    static func split(_ name: String, isFolder: Bool) -> (base: String, ext: String?) {
        guard !isFolder else { return (name, nil) }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        guard !ext.isEmpty, !base.isEmpty else { return (name, nil) }
        return (base, ext)
    }

    static func join(_ base: String, _ ext: String?) -> String {
        guard let ext, !ext.isEmpty else { return base }
        return "\(base).\(ext)"
    }

    /// "New folder", then "New folder (2)", "New folder (3)" …
    static func uniqueName(base: String, ext: String?, exists: (String) -> Bool) -> String {
        var candidate = join(base, ext)
        var counter = 2
        while exists(candidate) {
            candidate = join("\(base) (\(counter))", ext)
            counter += 1
        }
        return candidate
    }

    /// Pasting into the same folder: "report - Copy.txt", then "report - Copy (2).txt" …
    static func copyName(for name: String, isFolder: Bool, exists: (String) -> Bool) -> String {
        let (base, ext) = split(name, isFolder: isFolder)
        return uniqueName(base: "\(base) - Copy", ext: ext, exists: exists)
    }

    /// Renaming several items at once: "Holiday (1).jpg", "Holiday (2).png" … each keeps its own extension.
    static func batchNames(base: String, originals: [(name: String, isFolder: Bool)]) -> [String] {
        originals.enumerated().map { index, original in
            let ext = split(original.name, isFolder: original.isFolder).ext
            return join("\(base) (\(index + 1))", ext)
        }
    }

    /// Characters macOS will not accept in a file name.
    static let invalidCharacters = CharacterSet(charactersIn: "/:")

    static func validate(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "You must type a file name." }
        if trimmed.rangeOfCharacter(from: invalidCharacters) != nil {
            return "A file name can't contain any of the following characters: / :"
        }
        if trimmed == "." || trimmed == ".." { return "The specified file name is not valid." }
        return nil
    }
}
