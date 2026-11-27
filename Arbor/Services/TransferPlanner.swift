import Foundation

/// Works out the file operations for a copy or move, the Explorer way:
/// - pasting into the same folder makes "name - Copy";
/// - a file name clash asks Replace / Skip / Keep both;
/// - a folder name clash asks whether to **merge** the folders, and merging walks both trees,
///   asking again only for files that clash inside them.
///
/// The questions are asked through closures, so the planner itself is pure and unit-tested.
struct TransferPlanner {
    enum FileChoice { case replace, skip, keepBoth, cancel }
    enum FolderChoice { case merge, skip, keepBoth, cancel }

    struct Conflict {
        let name: String
        let destinationFolder: URL
        /// How many clashes of this kind are still to come (including this one), for "Do this for all".
        let remaining: Int
    }

    enum Failure: Error, Equatable {
        case intoItself(name: String)
        case cancelled
    }

    var askAboutFile: (Conflict) -> (FileChoice, applyToAll: Bool)
    var askAboutFolder: (Conflict) -> (FolderChoice, applyToAll: Bool)
    var fileManager = FileManager.default

    private struct State {
        var fileChoice: FileChoice?
        var folderChoice: FolderChoice?
        var fileConflictsLeft = 0
        var folderConflictsLeft = 0
    }

    func plan(sources: [URL], into folder: URL, move: Bool) -> Result<[FileOp], Failure> {
        for source in sources where source.isSameItem(as: folder) || folder.isDescendant(of: source) {
            return .failure(.intoItself(name: source.lastPathComponent))
        }
        var state = State()
        for source in sources where !source.parentFolder.isSameItem(as: folder) {
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            guard exists(destination) else { continue }
            if isMergeableFolder(source) && isMergeableFolder(destination) {
                state.folderConflictsLeft += 1
            } else {
                state.fileConflictsLeft += 1
            }
        }
        var ops: [FileOp] = []
        do {
            try planLevel(sources: sources, into: folder, move: move, insideMerge: false, state: &state, ops: &ops)
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.cancelled)
        }
        return .success(ops)
    }

    /// `insideMerge`: folders inside a folder being merged merge too, without asking again (as in Explorer).
    private func planLevel(sources: [URL], into folder: URL, move: Bool, insideMerge: Bool, state: inout State, ops: inout [FileOp]) throws {
        var plannedNames = Set<String>()
        func taken(_ name: String) -> Bool {
            plannedNames.contains(name.lowercased()) || exists(folder.appendingPathComponent(name))
        }

        for source in sources {
            let isFolder = isFolderLike(source)

            if source.parentFolder.isSameItem(as: folder) {
                guard !move else { continue }  // Moving onto itself does nothing.
                let name = NameGenerator.copyName(for: source.lastPathComponent, isFolder: isFolder, exists: taken)
                plannedNames.insert(name.lowercased())
                ops.append(.copy(source, folder.appendingPathComponent(name)))
                continue
            }

            let destination = folder.appendingPathComponent(source.lastPathComponent)
            let transfer: (URL) -> FileOp = { move ? .move(source, $0) : .copy(source, $0) }

            guard exists(destination) || plannedNames.contains(source.lastPathComponent.lowercased()) else {
                plannedNames.insert(source.lastPathComponent.lowercased())
                ops.append(transfer(destination))
                continue
            }

            func keepBoth() {
                let (base, ext) = NameGenerator.split(source.lastPathComponent, isFolder: isFolder)
                let name = NameGenerator.uniqueName(base: base, ext: ext, exists: taken)
                plannedNames.insert(name.lowercased())
                ops.append(transfer(folder.appendingPathComponent(name)))
            }

            if isMergeableFolder(source) && isMergeableFolder(destination) {
                let choice: FolderChoice
                if insideMerge {
                    choice = .merge
                } else if let remembered = state.folderChoice {
                    choice = remembered
                } else {
                    let answer = askAboutFolder(Conflict(name: source.lastPathComponent, destinationFolder: folder, remaining: max(state.folderConflictsLeft, 1)))
                    choice = answer.0
                    if answer.applyToAll { state.folderChoice = choice }
                }
                if !insideMerge { state.folderConflictsLeft -= 1 }
                switch choice {
                case .cancel:
                    throw Failure.cancelled
                case .skip:
                    continue
                case .keepBoth:
                    keepBoth()
                case .merge:
                    let children = (try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [])) ?? []
                    let sorted = children.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    // Clashes inside the merged folders count towards "Do this for the next N conflicts".
                    for child in sorted where exists(destination.appendingPathComponent(child.lastPathComponent)) {
                        if !(isMergeableFolder(child) && isMergeableFolder(destination.appendingPathComponent(child.lastPathComponent))) {
                            state.fileConflictsLeft += 1
                        }
                    }
                    try planLevel(sources: sorted, into: destination.normalizedFolder, move: move, insideMerge: true, state: &state, ops: &ops)
                    // A move leaves the source folder behind; remove it once it's empty.
                    if move { ops.append(.removeEmptyFolder(source)) }
                }
                continue
            }

            let choice: FileChoice
            if let remembered = state.fileChoice {
                choice = remembered
            } else {
                let answer = askAboutFile(Conflict(name: source.lastPathComponent, destinationFolder: folder, remaining: max(state.fileConflictsLeft, 1)))
                choice = answer.0
                if answer.applyToAll { state.fileChoice = choice }
            }
            state.fileConflictsLeft -= 1
            switch choice {
            case .cancel:
                throw Failure.cancelled
            case .skip:
                continue
            case .replace:
                ops.append(.trash(destination))
                ops.append(transfer(destination))
            case .keepBoth:
                keepBoth()
            }
        }
    }

    private func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    private func isFolderLike(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// Real folders merge; packages such as .app bundles behave like files.
    private func isMergeableFolder(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isPackage != true && values.isSymbolicLink != true
    }
}
