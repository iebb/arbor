import AppKit

/// Runs every file-system change Arbor makes, with one app-wide Undo/Redo stack
/// (Explorer's Ctrl+Z works across windows), conflict prompts and a progress window.
@MainActor
final class FileOperationService {
    static let shared = FileOperationService()

    let undoManager: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 100
        return manager
    }()

    private init() {}

    // MARK: - Running operations

    /// Runs `ops` in the background, showing progress if it takes a while, then registers Undo.
    func run(
        _ ops: [FileOp],
        actionName: String,
        progressTitle: String,
        window: NSWindow?,
        presentErrors: Bool = true,
        completion: (([FileChange], Error?) -> Void)? = nil
    ) {
        guard !ops.isEmpty else {
            completion?([], nil)
            return
        }
        let progress = OperationProgress(total: ops.count)
        let progressWindow = ProgressWindowController(title: progressTitle, progress: progress)
        progressWindow.scheduleShow(after: 0.6, over: window)

        Task.detached(priority: .userInitiated) {
            let engine = FileOpEngine(fileManager: FileManager())
            var changes: [FileChange] = []
            var failure: Error?
            for (index, op) in ops.enumerated() {
                if progress.isCancelled { break }
                progress.update(completed: index, currentName: op.itemName)
                do {
                    if let change = try engine.apply(op) { changes.append(change) }
                } catch {
                    failure = error
                    break
                }
            }
            progress.update(completed: ops.count, currentName: "")
            let finalChanges = changes
            let finalError = failure
            await MainActor.run {
                progressWindow.finish()
                let service = FileOperationService.shared
                service.didApply(finalChanges, actionName: actionName)
                if let finalError, presentErrors { service.present(finalError, window: window) }
                completion?(finalChanges, finalError)
            }
        }
    }

    /// Runs quick operations (rename, new folder, undo/redo) right away on the main thread.
    @discardableResult
    func runNow(_ ops: [FileOp], actionName: String, window: NSWindow?) -> [FileChange] {
        let engine = FileOpEngine(fileManager: FileManager.default)
        var changes: [FileChange] = []
        for op in ops {
            do {
                if let change = try engine.apply(op) { changes.append(change) }
            } catch {
                present(error, window: window)
                break
            }
        }
        didApply(changes, actionName: actionName)
        return changes
    }

    private func didApply(_ changes: [FileChange], actionName: String) {
        guard !changes.isEmpty else { return }
        registerUndo(for: changes, actionName: actionName)
        let folders = Array(Set(changes.flatMap(\.affectedFolders).map(\.pathKey))).map { URL(fileURLWithPath: $0, isDirectory: true) }
        NotificationCenter.default.post(name: .arborFoldersChanged, object: self, userInfo: ["folders": folders])
    }

    private func registerUndo(for changes: [FileChange], actionName: String) {
        let inverse = changes.reversed().compactMap(\.inverse)
        guard !inverse.isEmpty else { return }
        undoManager.registerUndo(withTarget: self) { service in
            // Runs synchronously so NSUndoManager files the reverse action under Redo.
            service.runNow(inverse, actionName: actionName, window: NSApp.keyWindow)
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - Copy / move

    enum ConflictChoice { case replace, skip, keepBoth, cancel }

    /// Pastes or drops `sources` into `folder`. Calls back with the URLs of the new items.
    func transfer(_ sources: [URL], to folder: URL, move: Bool, window: NSWindow?, completion: (([URL]) -> Void)? = nil) {
        guard let ops = plan(sources: sources, into: folder, move: move, window: window), !ops.isEmpty else {
            completion?([])
            return
        }
        let count = sources.count
        let verb = move ? "Moving" : "Copying"
        let title = "\(verb) \(Format.items(count)) to “\(Location.displayName(of: folder))”"
        run(ops, actionName: move ? "Move" : "Copy", progressTitle: title, window: window) { changes, _ in
            completion?(changes.compactMap { change in
                switch change {
                case .copied, .moved: return change.resultURL
                default: return nil
                }
            })
        }
    }

    /// Works out the operations for a copy or move, asking about name conflicts like Explorer.
    private func plan(sources: [URL], into folder: URL, move: Bool, window: NSWindow?) -> [FileOp]? {
        let fm = FileManager.default
        var ops: [FileOp] = []
        var plannedNames = Set<String>()
        var rememberedChoice: ConflictChoice?

        func taken(_ name: String) -> Bool {
            plannedNames.contains(name.lowercased()) || fm.fileExists(atPath: folder.appendingPathComponent(name).path)
        }

        let conflicts = sources.filter { source in
            !source.parentFolder.isSameItem(as: folder) && fm.fileExists(atPath: folder.appendingPathComponent(source.lastPathComponent).path)
        }
        var conflictsLeft = conflicts.count

        for source in sources {
            if source.isSameItem(as: folder) || folder.isDescendant(of: source) {
                showAlert(
                    message: "The destination folder is a subfolder of the source folder.",
                    info: "“\(source.lastPathComponent)” can't be \(move ? "moved" : "copied") into itself.",
                    window: window
                )
                return nil
            }
            let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

            if source.parentFolder.isSameItem(as: folder) {
                guard !move else { continue }  // Moving onto itself does nothing.
                let name = NameGenerator.copyName(for: source.lastPathComponent, isFolder: isFolder, exists: taken)
                plannedNames.insert(name.lowercased())
                ops.append(.copy(source, folder.appendingPathComponent(name)))
                continue
            }

            let destination = folder.appendingPathComponent(source.lastPathComponent)
            let transferOp: (URL) -> FileOp = { move ? .move(source, $0) : .copy(source, $0) }

            guard fm.fileExists(atPath: destination.path) || plannedNames.contains(source.lastPathComponent.lowercased()) else {
                plannedNames.insert(source.lastPathComponent.lowercased())
                ops.append(transferOp(destination))
                continue
            }

            let choice: ConflictChoice
            if let rememberedChoice {
                choice = rememberedChoice
            } else {
                let answer = askAboutConflict(name: source.lastPathComponent, isFolder: isFolder, folder: folder, remaining: conflictsLeft)
                choice = answer.choice
                if answer.applyToAll { rememberedChoice = choice }
            }
            conflictsLeft -= 1

            switch choice {
            case .cancel:
                return nil
            case .skip:
                continue
            case .replace:
                ops.append(.trash(destination))
                ops.append(transferOp(destination))
            case .keepBoth:
                let (base, ext) = NameGenerator.split(source.lastPathComponent, isFolder: isFolder)
                let name = NameGenerator.uniqueName(base: base, ext: ext, exists: taken)
                plannedNames.insert(name.lowercased())
                ops.append(transferOp(folder.appendingPathComponent(name)))
            }
        }
        return ops
    }

    private func askAboutConflict(name: String, isFolder: Bool, folder: URL, remaining: Int) -> (choice: ConflictChoice, applyToAll: Bool) {
        let alert = NSAlert()
        alert.messageText = "The destination already has a \(isFolder ? "folder" : "file") named “\(name)”"
        alert.informativeText = "in “\(Location.displayName(of: folder))”. Replacing moves the existing item to the Trash."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Cancel")
        if remaining > 1 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Do this for the next \(remaining - 1) conflict\(remaining - 1 == 1 ? "" : "s")"
        }
        let response = alert.runModal()
        let applyToAll = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn: return (.replace, applyToAll)
        case .alertSecondButtonReturn: return (.skip, applyToAll)
        case .alertThirdButtonReturn: return (.keepBoth, applyToAll)
        default: return (.cancel, false)
        }
    }

    // MARK: - Delete

    func trash(_ urls: [URL], window: NSWindow?) {
        guard !urls.isEmpty else { return }
        let title = "Moving \(Format.items(urls.count)) to the Trash"
        run(urls.map { .trash($0) }, actionName: "Delete", progressTitle: title, window: window, presentErrors: false) { [weak self] changes, error in
            guard let self, let error else { return }
            let done = Set(changes.compactMap { change -> String? in
                if case .trashed(let original, _) = change { return original.pathKey }
                return nil
            })
            let remaining = urls.filter { !done.contains($0.pathKey) }
            let nsError = error as NSError
            let noTrash = nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.featureUnsupported.rawValue
            if noTrash, let first = remaining.first {
                let alert = NSAlert()
                alert.messageText = remaining.count == 1
                    ? "“\(first.lastPathComponent)” can't be moved to the Trash."
                    : "These \(remaining.count) items can't be moved to the Trash."
                alert.informativeText = "This drive doesn't have a Trash. Do you want to delete \(remaining.count == 1 ? "it" : "them") permanently?"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Delete")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    self.deletePermanently(remaining, window: window, confirm: false)
                }
            } else {
                self.present(error, window: window)
            }
        }
    }

    /// Shift+Delete: no Trash, no Undo, so Explorer asks first.
    func deletePermanently(_ urls: [URL], window: NSWindow?, confirm: Bool = true) {
        guard let first = urls.first else { return }
        if confirm {
            let alert = NSAlert()
            alert.messageText = urls.count == 1
                ? "Are you sure you want to permanently delete “\(first.lastPathComponent)”?"
                : "Are you sure you want to permanently delete these \(urls.count) items?"
            alert.informativeText = "You can't undo this action."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        run(urls.map { .remove($0) }, actionName: "Delete", progressTitle: "Deleting \(Format.items(urls.count))", window: window) { _, _ in
            let folders = Array(Set(urls.map { $0.parentFolder.pathKey })).map { URL(fileURLWithPath: $0, isDirectory: true) }
            NotificationCenter.default.post(name: .arborFoldersChanged, object: self, userInfo: ["folders": folders])
        }
    }

    // MARK: - Rename and create

    /// Renames one item. Returns the new URL, or nil if nothing changed.
    @discardableResult
    func rename(_ url: URL, to newName: String, window: NSWindow?) -> URL? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != url.lastPathComponent else { return nil }
        if let problem = NameGenerator.validate(trimmed) {
            showAlert(message: problem, info: nil, window: window)
            return nil
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        let caseOnly = destination.pathKey.lowercased() == url.pathKey.lowercased()
        if !caseOnly && FileManager.default.fileExists(atPath: destination.path) {
            showAlert(message: "There is already a file with the same name in this location.", info: "“\(trimmed)”", window: window)
            return nil
        }
        let ops: [FileOp]
        if caseOnly {
            // Case-insensitive volumes need a detour to change only the letter case.
            let temp = url.deletingLastPathComponent().appendingPathComponent(".arbor-rename-\(UUID().uuidString)")
            ops = [.move(url, temp), .move(temp, destination)]
        } else {
            ops = [.move(url, destination)]
        }
        let changes = runNow(ops, actionName: "Rename", window: window)
        return changes.count == ops.count ? destination : nil
    }

    /// Explorer's multi-rename: "Holiday (1).jpg", "Holiday (2).jpg" … Returns (old, new) pairs.
    func batchRename(_ urls: [URL], base: String, window: NSWindow?) -> [(from: URL, to: URL)] {
        if let problem = NameGenerator.validate(base) {
            showAlert(message: problem, info: nil, window: window)
            return []
        }
        let originals = urls.map { url -> (name: String, isFolder: Bool) in
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return (url.lastPathComponent, isFolder)
        }
        let names = NameGenerator.batchNames(base: base.trimmingCharacters(in: .whitespaces), originals: originals)
        let batchPaths = Set(urls.map { $0.pathKey.lowercased() })
        // Two passes through temporary names so items can swap names safely.
        var firstPass: [FileOp] = []
        var secondPass: [FileOp] = []
        var results: [(from: URL, to: URL)] = []
        for (url, name) in zip(urls, names) where url.lastPathComponent != name {
            let destination = url.deletingLastPathComponent().appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) && !batchPaths.contains(destination.pathKey.lowercased()) { continue }
            let temp = url.deletingLastPathComponent().appendingPathComponent(".arbor-rename-\(UUID().uuidString)")
            firstPass.append(.move(url, temp))
            secondPass.append(.move(temp, destination))
            results.append((from: url, to: destination))
        }
        let changes = runNow(firstPass + secondPass, actionName: "Rename", window: window)
        return changes.count == firstPass.count * 2 ? results : []
    }

    func newFolder(in folder: URL, window: NSWindow?) -> URL? {
        let name = NameGenerator.uniqueName(base: "New folder", ext: nil) {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        let url = folder.appendingPathComponent(name, isDirectory: true)
        return runNow([.createFolder(url)], actionName: "New Folder", window: window).isEmpty ? nil : url
    }

    func newTextDocument(in folder: URL, window: NSWindow?) -> URL? {
        let name = NameGenerator.uniqueName(base: "New Text Document", ext: "txt") {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        let url = folder.appendingPathComponent(name)
        return runNow([.createFile(url)], actionName: "New Text Document", window: window).isEmpty ? nil : url
    }

    // MARK: - ZIP

    /// "Send to › Compressed (zipped) folder". Calls back with the new archive.
    func compress(_ urls: [URL], window: NSWindow?, completion: @escaping (URL?) -> Void) {
        guard let first = urls.first else { return completion(nil) }
        let folder = first.parentFolder
        let isFolder = (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let base = NameGenerator.split(first.lastPathComponent, isFolder: isFolder).base
        let zipName = NameGenerator.uniqueName(base: base, ext: "zip") {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        let destination = folder.appendingPathComponent(zipName)
        let arguments: [String]
        let tool: String
        if urls.count == 1 {
            tool = "/usr/bin/ditto"
            arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, destination.path]
        } else {
            tool = "/usr/bin/zip"
            arguments = ["-r", "-y", "-q", destination.path] + urls.map(\.lastPathComponent) + ["-x", "*.DS_Store"]
        }
        runTool(tool, arguments: arguments, in: folder, title: "Compressing \(Format.items(urls.count))", window: window) { [weak self] success in
            guard let self else { return }
            if success {
                self.didApply([.created(destination)], actionName: "Compress")
                completion(destination)
            } else {
                self.showAlert(message: "Arbor couldn't create “\(zipName)”.", info: nil, window: window)
                completion(nil)
            }
        }
    }

    /// "Extract All…" into a folder named after the archive.
    func extract(_ archive: URL, window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let folder = archive.parentFolder
        let base = NameGenerator.split(archive.lastPathComponent, isFolder: false).base
        let name = NameGenerator.uniqueName(base: base, ext: nil) {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        let destination = folder.appendingPathComponent(name, isDirectory: true)
        runTool("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, destination.path], in: folder, title: "Extracting “\(archive.lastPathComponent)”", window: window) { [weak self] success in
            guard let self else { return }
            if success {
                self.didApply([.created(destination)], actionName: "Extract")
                completion(destination)
            } else {
                self.showAlert(message: "Arbor couldn't extract “\(archive.lastPathComponent)”.", info: "The archive may be damaged or use an unsupported format.", window: window)
                completion(nil)
            }
        }
    }

    private func runTool(_ path: String, arguments: [String], in directory: URL, title: String, window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let progressWindow = ProgressWindowController(title: title, progress: nil)
        progressWindow.scheduleShow(after: 0.6, over: window)
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var success = false
            do {
                try process.run()
                process.waitUntilExit()
                success = process.terminationStatus == 0
            } catch {
                success = false
            }
            let result = success
            await MainActor.run {
                progressWindow.finish()
                completion(result)
            }
        }
    }

    // MARK: - Alerts

    func present(_ error: Error, window: NSWindow?) {
        let alert = NSAlert(error: error)
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func showAlert(message: String, info: String?, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info ?? ""
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
