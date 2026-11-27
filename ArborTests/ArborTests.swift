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
}
