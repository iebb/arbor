import XCTest
@testable import Arbor

final class NameGeneratorTests: XCTestCase {
    func testNewFolderNamesCountFromTwo() {
        var existing: Set<String> = []
        XCTAssertEqual(NameGenerator.uniqueName(base: "New folder", ext: nil) { existing.contains($0) }, "New folder")
        existing = ["New folder"]
        XCTAssertEqual(NameGenerator.uniqueName(base: "New folder", ext: nil) { existing.contains($0) }, "New folder (2)")
        existing = ["New folder", "New folder (2)"]
        XCTAssertEqual(NameGenerator.uniqueName(base: "New folder", ext: nil) { existing.contains($0) }, "New folder (3)")
    }

    func testCopyNamesFollowExplorer() {
        var existing: Set<String> = ["report.txt"]
        XCTAssertEqual(NameGenerator.copyName(for: "report.txt", isFolder: false) { existing.contains($0) }, "report - Copy.txt")
        existing.insert("report - Copy.txt")
        XCTAssertEqual(NameGenerator.copyName(for: "report.txt", isFolder: false) { existing.contains($0) }, "report - Copy (2).txt")
        XCTAssertEqual(NameGenerator.copyName(for: "my.folder", isFolder: true) { _ in false }, "my.folder - Copy")
    }

    func testDotfilesHaveNoExtension() {
        XCTAssertEqual(NameGenerator.split(".gitignore", isFolder: false).ext, nil)
        XCTAssertEqual(NameGenerator.split("archive.tar.gz", isFolder: false).ext, "gz")
    }

    func testBatchNamesKeepEachExtension() {
        let names = NameGenerator.batchNames(base: "Holiday", originals: [("a.jpg", false), ("b.png", false), ("c", true)])
        XCTAssertEqual(names, ["Holiday (1).jpg", "Holiday (2).png", "Holiday (3)"])
    }

    func testValidation() {
        XCTAssertNotNil(NameGenerator.validate("   "))
        XCTAssertNotNil(NameGenerator.validate("a/b"))
        XCTAssertNotNil(NameGenerator.validate("a:b"))
        XCTAssertNil(NameGenerator.validate("Quarterly report.docx"))
    }
}

final class NavigationHistoryTests: XCTestCase {
    private let a = Location.folder(URL(fileURLWithPath: "/a", isDirectory: true))
    private let b = Location.folder(URL(fileURLWithPath: "/b", isDirectory: true))
    private let c = Location.folder(URL(fileURLWithPath: "/c", isDirectory: true))

    func testBackAndForward() {
        var history = NavigationHistory(start: a)
        history.visit(b)
        history.visit(c)
        XCTAssertEqual(history.goBack(), b)
        XCTAssertEqual(history.goBack(), a)
        XCTAssertNil(history.goBack())
        XCTAssertEqual(history.goForward(steps: 2), c)
    }

    func testVisitingClearsForward() {
        var history = NavigationHistory(start: a)
        history.visit(b)
        history.goBack()
        history.visit(c)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.backStack, [a])
    }

    func testVisitingSameLocationIsIgnored() {
        var history = NavigationHistory(start: a)
        history.visit(a)
        XCTAssertFalse(history.canGoBack)
    }
}

final class FormatTests: XCTestCase {
    func testDetailsColumnRoundsUpToKilobytes() {
        XCTAssertEqual(Format.kilobytes(0), "0 KB")
        XCTAssertEqual(Format.kilobytes(1), "1 KB")
        XCTAssertEqual(Format.kilobytes(1024), "1 KB")
        XCTAssertEqual(Format.kilobytes(1025), "2 KB")
        XCTAssertEqual(Format.kilobytes(5_000_000), "4,883 KB")
        XCTAssertEqual(Format.kilobytes(nil), "")
    }

    func testStatusBarSizes() {
        XCTAssertEqual(Format.bytes(500), "500 bytes")
        XCTAssertEqual(Format.bytes(1536), "1.50 KB")
        XCTAssertEqual(Format.bytes(10 * 1024 * 1024), "10.0 MB")
        XCTAssertEqual(Format.bytes(200 * 1024 * 1024 * 1024), "200 GB")
    }
}

final class SortingTests: XCTestCase {
    private func item(_ name: String, folder: Bool = false, size: Int64? = nil) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, isDirectory: folder, isPackage: false,
                 isSymbolicLink: false, isAlias: false, isHidden: false, size: size, modified: nil, created: nil,
                 kind: folder ? "File folder" : "File", contentType: nil, linkedFolderURL: nil)
    }

    func testFoldersFirstAndNaturalOrder() {
        let items = [item("file10.txt"), item("Zeta", folder: true), item("file2.txt"), item("alpha", folder: true)]
        let sorted = items.sorted(by: SortOrder(key: .name, ascending: true)).map(\.name)
        XCTAssertEqual(sorted, ["alpha", "Zeta", "file2.txt", "file10.txt"])
    }

    func testDescendingPutsFoldersLast() {
        let items = [item("a", folder: true), item("b.txt")]
        XCTAssertEqual(items.sorted(by: SortOrder(key: .name, ascending: false)).map(\.name), ["b.txt", "a"])
    }

    func testSizeSort() {
        let items = [item("big", size: 900), item("small", size: 10), item("mid", size: 100)]
        XCTAssertEqual(items.sorted(by: SortOrder(key: .size, ascending: true)).map(\.name), ["small", "mid", "big"])
    }

    func testKnownExtensionsAreHidden() {
        XCTAssertEqual(item("photo.jpg").displayName(showExtensions: false), "photo")
        XCTAssertEqual(item("photo.jpg").displayName(showExtensions: true), "photo.jpg")
        XCTAssertEqual(item("data.zzzunknown").displayName(showExtensions: false), "data.zzzunknown")
    }
}

final class PathResolverTests: XCTestCase {
    private let check: PathResolver.ExistsCheck = { path in
        switch path {
        case "/Users/me", "/Users/me/Documents": return (true, true)
        case "/Users/me/notes.txt": return (true, false)
        default: return (false, false)
        }
    }

    func testResolvesFoldersFilesAndSpecialNames() {
        XCTAssertEqual(PathResolver.resolve("This Mac", relativeTo: nil, check: check), .location(.thisMac))
        XCTAssertEqual(PathResolver.resolve("\"/Users/me/Documents\"", relativeTo: nil, check: check),
                       .location(.folder(URL(fileURLWithPath: "/Users/me/Documents", isDirectory: true))))
        XCTAssertEqual(PathResolver.resolve("Documents", relativeTo: URL(fileURLWithPath: "/Users/me", isDirectory: true), check: check),
                       .location(.folder(URL(fileURLWithPath: "/Users/me/Documents", isDirectory: true))))
        XCTAssertEqual(PathResolver.resolve("/Users/me/notes.txt", relativeTo: nil, check: check),
                       .file(URL(fileURLWithPath: "/Users/me/notes.txt", isDirectory: false)))
        XCTAssertEqual(PathResolver.resolve("/nope", relativeTo: nil, check: check), .notFound("/nope"))
        XCTAssertEqual(PathResolver.resolve("https://example.com", relativeTo: nil, check: check), .web(URL(string: "https://example.com")!))
    }
}

final class URLHelperTests: XCTestCase {
    func testFolderChain() {
        let chain = URL(fileURLWithPath: "/Users/me/a/b").folderChain(below: URL(fileURLWithPath: "/Users/me"))
        XCTAssertEqual(chain.map(\.pathKey), ["/Users/me/a", "/Users/me/a/b"])
        let fromRoot = URL(fileURLWithPath: "/Users").folderChain(below: URL(fileURLWithPath: "/"))
        XCTAssertEqual(fromRoot.map(\.pathKey), ["/Users"])
    }

    func testDescendant() {
        XCTAssertTrue(URL(fileURLWithPath: "/a/b").isDescendant(of: URL(fileURLWithPath: "/a")))
        XCTAssertFalse(URL(fileURLWithPath: "/ab").isDescendant(of: URL(fileURLWithPath: "/a")))
        XCTAssertFalse(URL(fileURLWithPath: "/a").isDescendant(of: URL(fileURLWithPath: "/a")))
    }

    func testFileChangeInverse() {
        let a = URL(fileURLWithPath: "/x/a"), b = URL(fileURLWithPath: "/y/a")
        guard case let .move(from, to)? = FileChange.moved(from: a, to: b).inverse else { return XCTFail() }
        XCTAssertEqual(from, b)
        XCTAssertEqual(to, a)
        guard case let .trash(url)? = FileChange.copied(from: a, to: b).inverse else { return XCTFail() }
        XCTAssertEqual(url, b)
        XCTAssertNil(FileChange.trashed(original: a, trashURL: nil).inverse)
    }
}

final class FolderOptionsTests: XCTestCase {
    func testExplorerDefaults() {
        XCTAssertFalse(FolderOption.showExtensions.defaultValue, "known extensions are hidden by default")
        XCTAssertFalse(FolderOption.showHidden.defaultValue)
        XCTAssertTrue(FolderOption.hideProtectedSystemFiles.defaultValue)
        XCTAssertTrue(FolderOption.showStatusBar.defaultValue)
        XCTAssertFalse(FolderOption.singleClickToOpen.defaultValue)
        XCTAssertTrue(FolderOption.searchSystemDirectories.defaultValue)
        XCTAssertFalse(FolderOption.searchFileContents.defaultValue)
        XCTAssertFalse(FolderOption.showDetailsPane.defaultValue)
        XCTAssertFalse(FolderOption.showDetailsPane.postsChange)
    }

    func testEveryDialogOptionBelongsToOneTab() {
        let tabs = FolderOption.generalTab + FolderOption.viewTab + FolderOption.searchTab
        XCTAssertEqual(tabs.count, Set(tabs).count)
    }

    func testSingleClickUnderlineAndCheckBoxRules() {
        var display = DisplayOptions()
        XCTAssertFalse(display.underlines(hovered: true), "double-click mode never underlines")
        display.singleClickToOpen = true
        XCTAssertTrue(display.underlines(hovered: true))
        XCTAssertFalse(display.underlines(hovered: false))
        display.underlineOnlyOnHover = false
        XCTAssertTrue(display.underlines(hovered: false))

        XCTAssertFalse(display.showsCheckBox(selected: true, hovered: true))
        display.checkBoxes = true
        XCTAssertTrue(display.showsCheckBox(selected: true, hovered: false))
        XCTAssertTrue(display.showsCheckBox(selected: false, hovered: true))
        XCTAssertFalse(display.showsCheckBox(selected: false, hovered: false))
    }

    func testProtectedFiles() {
        XCTAssertTrue(ProtectedFiles.isProtected(URL(fileURLWithPath: "/tmp/x/.DS_Store")))
        XCTAssertTrue(ProtectedFiles.isProtected(URL(fileURLWithPath: "/tmp/x/._photo.jpg")))
        XCTAssertTrue(ProtectedFiles.isProtected(URL(fileURLWithPath: "/usr")))
        XCTAssertFalse(ProtectedFiles.isProtected(URL(fileURLWithPath: "/Users")))
        XCTAssertFalse(ProtectedFiles.isProtected(URL(fileURLWithPath: "/Users/me/usr")))
        XCTAssertFalse(ProtectedFiles.isProtected(URL(fileURLWithPath: "/tmp/x/.gitignore")))
    }
}

final class SearchServiceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ArborSearch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try "the quarterly budget".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "nothing here".write(to: root.appendingPathComponent("inner/other.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("inner/secretplan.txt"), atomically: true, encoding: .utf8)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-q", "bundle.zip", "inner/secretplan.txt"]
        try zip.run()
        zip.waitUntilExit()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func names(_ query: String, contents: Bool = false, zips: Bool = false) async -> Set<String> {
        let options = SearchOptions(showHidden: false, hideProtected: true, includeSystemDirectories: true, includeCompressedFiles: zips, searchContents: contents)
        var found = Set<String>()
        for await batch in SearchService.search(root: root, query: query, options: options) {
            batch.forEach { found.insert($0.name) }
        }
        return found
    }

    func testNameSearchIgnoresContentsByDefault() async {
        let found = await names("budget")
        XCTAssertEqual(found, [])
    }

    func testContentSearch() async {
        let found = await names("BUDGET", contents: true)
        XCTAssertEqual(found, ["notes.txt"])
    }

    func testZipEntriesMatchTheArchive() async {
        let withoutZips = await names("secretplan")
        XCTAssertEqual(withoutZips, ["secretplan.txt"])
        let withZips = await names("secretplan", zips: true)
        XCTAssertEqual(withZips, ["secretplan.txt", "bundle.zip"])
    }

    func testWildcards() async {
        let found = await names("*.zip")
        XCTAssertEqual(found, ["bundle.zip"])
    }

    func testSpotlightQueryFormatting() {
        XCTAssertNil(SearchService.spotlightQuery(for: "   ", searchContents: false))
        XCTAssertEqual(
            SearchService.spotlightQuery(for: "report", searchContents: false),
            "kMDItemFSName == '*report*'cd"
        )
        XCTAssertEqual(
            SearchService.spotlightQuery(for: "report", searchContents: true),
            "(kMDItemFSName == '*report*'cd || kMDItemTextContent == '*report*'cd)"
        )
        XCTAssertEqual(
            SearchService.spotlightQuery(for: "*.pdf", searchContents: true),
            "kMDItemFSName == '*.pdf'cd"
        )
        XCTAssertEqual(
            SearchService.spotlightQuery(for: "it's", searchContents: false),
            "kMDItemFSName == '*it\\'s*'cd"
        )
        XCTAssertFalse(SearchService.isSpotlightIndexed(root))
    }
}

final class FolderMergeTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ArborMerge-\(UUID().uuidString)", isDirectory: true)
        // src/Photos/{a.jpg, same.jpg, Trip/x.jpg}   dst/Photos/{same.jpg, b.jpg, Trip/y.jpg}
        for path in ["src/Photos/Trip", "dst/Photos/Trip"] {
            try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        for (path, text) in [("src/Photos/a.jpg", "a"), ("src/Photos/same.jpg", "new"), ("src/Photos/Trip/x.jpg", "x"),
                             ("dst/Photos/same.jpg", "old"), ("dst/Photos/b.jpg", "b"), ("dst/Photos/Trip/y.jpg", "y")] {
            try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    private func read(_ path: String) -> String? { try? String(contentsOf: url(path), encoding: .utf8) }

    private func planner(file: TransferPlanner.FileChoice, folder: TransferPlanner.FolderChoice, asked: UnsafeMutablePointer<[String]>? = nil) -> TransferPlanner {
        TransferPlanner(
            askAboutFile: { conflict in asked?.pointee.append("file:\(conflict.name)"); return (file, false) },
            askAboutFolder: { conflict in asked?.pointee.append("folder:\(conflict.name)"); return (folder, false) }
        )
    }

    /// Applies the ops like FileOperationService does and returns the changes (for undo).
    private func apply(_ ops: [FileOp]) throws -> [FileChange] {
        let engine = FileOpEngine(fileManager: fm)
        return try ops.compactMap { try engine.apply($0) }
    }

    private func undo(_ changes: [FileChange]) throws {
        _ = try apply(changes.reversed().compactMap(\.inverse))
    }

    func testCopyMergeAsksOnlyAboutClashingFiles() throws {
        var asked: [String] = []
        let result = withUnsafeMutablePointer(to: &asked) { pointer in
            planner(file: .replace, folder: .merge, asked: pointer).plan(sources: [url("src/Photos")], into: url("dst"), move: false)
        }
        let changes = try apply(try result.get())
        XCTAssertEqual(asked, ["folder:Photos", "file:same.jpg"], "Trip merges silently; only same.jpg clashes")
        XCTAssertEqual(read("dst/Photos/a.jpg"), "a")
        XCTAssertEqual(read("dst/Photos/b.jpg"), "b", "merge keeps files only in the destination")
        XCTAssertEqual(read("dst/Photos/same.jpg"), "new")
        XCTAssertEqual(read("dst/Photos/Trip/x.jpg"), "x")
        XCTAssertEqual(read("dst/Photos/Trip/y.jpg"), "y")
        XCTAssertEqual(read("src/Photos/a.jpg"), "a", "copy leaves the source alone")

        try undo(changes)
        XCTAssertNil(read("dst/Photos/a.jpg"))
        XCTAssertNil(read("dst/Photos/Trip/x.jpg"))
        XCTAssertEqual(read("dst/Photos/same.jpg"), "old", "undo brings the replaced file back from the Trash")
    }

    func testMoveMergeRemovesTheEmptiedSourceAndUndoes() throws {
        let ops = try planner(file: .keepBoth, folder: .merge).plan(sources: [url("src/Photos")], into: url("dst"), move: true).get()
        let changes = try apply(ops)
        XCTAssertFalse(fm.fileExists(atPath: url("src/Photos").path), "the emptied source folder is removed")
        XCTAssertEqual(read("dst/Photos/same.jpg"), "old")
        XCTAssertEqual(read("dst/Photos/same (2).jpg"), "new")
        XCTAssertEqual(read("dst/Photos/Trip/x.jpg"), "x")

        try undo(changes)
        XCTAssertEqual(read("src/Photos/a.jpg"), "a")
        XCTAssertEqual(read("src/Photos/same.jpg"), "new")
        XCTAssertEqual(read("src/Photos/Trip/x.jpg"), "x")
        XCTAssertNil(read("dst/Photos/a.jpg"))
        XCTAssertNil(read("dst/Photos/same (2).jpg"))
        XCTAssertEqual(read("dst/Photos/same.jpg"), "old")
    }

    func testSkippedFileKeepsSourceFolderOnMove() throws {
        let ops = try planner(file: .skip, folder: .merge).plan(sources: [url("src/Photos")], into: url("dst"), move: true).get()
        _ = try apply(ops)
        XCTAssertEqual(read("src/Photos/same.jpg"), "new", "a skipped file stays behind")
        XCTAssertTrue(fm.fileExists(atPath: url("src/Photos").path), "so its folder isn't removed")
        XCTAssertEqual(read("dst/Photos/same.jpg"), "old")
    }

    func testFolderKeepBothAndSkip() throws {
        _ = try apply(try planner(file: .replace, folder: .keepBoth).plan(sources: [url("src/Photos")], into: url("dst"), move: false).get())
        XCTAssertEqual(read("dst/Photos (2)/same.jpg"), "new")
        XCTAssertEqual(read("dst/Photos/same.jpg"), "old")

        let skipped = try planner(file: .replace, folder: .skip).plan(sources: [url("src/Photos")], into: url("dst"), move: false).get()
        XCTAssertTrue(skipped.isEmpty)
    }

    func testCancelAndIntoItself() {
        XCTAssertEqual(planner(file: .replace, folder: .cancel).plan(sources: [url("src/Photos")], into: url("dst"), move: false), .failure(.cancelled))
        XCTAssertEqual(planner(file: .replace, folder: .merge).plan(sources: [url("src")], into: url("src/Photos"), move: true), .failure(.intoItself(name: "src")))
    }
}

final class GroupingTests: XCTestCase {
    private func item(_ name: String, folder: Bool = false, size: Int64? = nil, modified: Date? = nil, kind: String = "File") -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, isDirectory: folder, isPackage: false,
                 isSymbolicLink: false, isAlias: false, isHidden: false, size: folder ? nil : size, modified: modified, created: nil,
                 kind: folder ? "File folder" : kind, contentType: nil, linkedFolderURL: nil)
    }

    func testNameRanges() {
        let groups = FileGrouping.groups([item("apple"), item("2024"), item("zebra"), item("Kiwi"), item("日本")], by: .name)
        XCTAssertEqual(groups.map(\.title), ["0 – 9", "A – H", "I – P", "Q – Z", "Other"])
    }

    func testSizeBucketsBiggestFirstAndFoldersLast() {
        let groups = FileGrouping.groups([item("a", size: 0), item("b", size: 5_000), item("c", size: 5_000_000_000), item("d", folder: true)], by: .size)
        XCTAssertEqual(groups.map(\.title), ["Gigantic (> 4 GB)", "Tiny (0 – 16 KB)", "Empty (0 KB)", "Unspecified"])
    }

    func testDateBucketsNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 12))!  // a Friday
        let day: (Int) -> Date = { calendar.date(byAdding: .day, value: -$0, to: now)! }
        let items = [item("old", modified: day(400)), item("today", modified: day(0)), item("yesterday", modified: day(1)), item("none")]
        let groups = FileGrouping.groups(items, by: .dateModified, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday", "A long time ago", "Unspecified"])
    }

    func testGroupsKeepSortOrderAndTypeGroupsPutFoldersFirst() {
        let items = [item("b.txt", kind: "Text"), item("Docs", folder: true), item("a.txt", kind: "Text"), item("x.pdf", kind: "PDF")]
        let groups = FileGrouping.groups(items, by: .type)
        XCTAssertEqual(groups.map(\.title), ["File folder", "PDF", "Text"])
        XCTAssertEqual(groups[2].items.map(\.name), ["b.txt", "a.txt"], "grouping doesn't re-sort")
    }

    func testOldViewSettingsStillDecode() {
        XCTAssertEqual(FolderViewSettings(encoded: "details|name|1")?.groupBy, GroupKey.none)
        let settings = FolderViewSettings(viewMode: .content, sort: SortOrder(key: .size, ascending: false), groupBy: .type)
        XCTAssertEqual(FolderViewSettings(encoded: settings.encoded), settings)
    }
}

final class NetworkLocationTests: XCTestCase {
    func testServerAddresses() {
        XCTAssertEqual(NetworkLocations.normalizedURL("\\\\nas\\Share\\Photos")?.absoluteString, "smb://nas/Share/Photos")
        XCTAssertEqual(NetworkLocations.normalizedURL("nas.local/Share")?.absoluteString, "smb://nas.local/Share")
        XCTAssertEqual(NetworkLocations.normalizedURL("afp://mac.local/Home")?.scheme, "afp")
        XCTAssertEqual(NetworkLocations.normalizedURL("smb://nas/My Files")?.path, "/My Files")
        XCTAssertNil(NetworkLocations.normalizedURL("  "))
        XCTAssertNil(NetworkLocations.normalizedURL("gopher://old"))
        XCTAssertTrue(NetworkLocations.isMountable(URL(string: "smb://nas/a")!))
        XCTAssertFalse(NetworkLocations.isMountable(URL(string: "https://example.com")!))
    }

    func testDisplayName() {
        XCTAssertEqual(NetworkLocation(address: "smb://nas/Share", reconnectAtLaunch: false).displayName, "Share (nas)")
        XCTAssertEqual(NetworkLocation(address: "smb://nas", reconnectAtLaunch: false).displayName, "nas")
    }
}

final class FileClipboardTests: XCTestCase {
    func testCutCopyCancelAndClear() {
        let clipboard = FileClipboard.shared
        let sample = URL(fileURLWithPath: "/tmp/arbor-clipboard-test.txt")
        clipboard.write([sample], cut: true)
        XCTAssertTrue(clipboard.isCut)
        XCTAssertTrue(clipboard.hasFiles)
        XCTAssertEqual(clipboard.cutPaths, [sample.pathKey])

        clipboard.cancelCut()
        XCTAssertFalse(clipboard.isCut)
        XCTAssertTrue(clipboard.cutPaths.isEmpty)

        clipboard.write([sample], cut: true)
        XCTAssertTrue(clipboard.isCut)
        clipboard.clearAfterMove()
        XCTAssertFalse(clipboard.isCut)
        XCTAssertFalse(clipboard.hasFiles)
    }
}
