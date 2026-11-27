# Arbor

[![CI](https://github.com/iebb/arbor/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/iebb/arbor/actions/workflows/ci.yml)

**A native macOS file manager that works like Windows File Explorer.**

Arbor gives people coming from Windows the Explorer they know: a folder tree on the left, a
breadcrumb address bar you can type into, real Cut & Paste (`⌘X` / `⌘V`), Enter to open, F2 to rename, Backspace
to go back, and the familiar command bar, Details columns and status bar. It is written in Swift and
AppKit, so it still feels at home on the Mac — native tabs, Quick Look, the Trash, drag and drop with
Finder, and dark mode.

![Arbor Details view with Details pane](docs/screenshots/details-en.png)

| Large Icons & Details Pane (Dark Mode) | Folder Options (Settings) |
| :---: | :---: |
| ![Arbor Dark Mode Photos](docs/screenshots/photos-dark-en.png) | ![Arbor Folder Options](docs/screenshots/settings-en.png) |

| Collapsible Groups | Properties & This Mac |
| :---: | :---: |
| ![Arbor Collapsible Groups](docs/screenshots/grouped-en.png) | ![Arbor Properties](docs/screenshots/properties-en.png) |

![Arbor This Mac view](docs/screenshots/thismac-en.png)

<details>
<summary>中文界面截图 / Simplified Chinese Screenshots</summary>

| 详细信息与详细信息窗格 | 深色模式大图标 |
| :---: | :---: |
| ![Arbor 中文详细信息](docs/screenshots/details-zh.png) | ![Arbor 中文深色模式](docs/screenshots/photos-dark-zh.png) |

| 文件夹选项 | 属性与分组 |
| :---: | :---: |
| ![Arbor 文件夹选项](docs/screenshots/settings-zh.png) | ![Arbor 属性](docs/screenshots/properties-zh.png) |

</details>

## Features

**Window layout (Explorer, top to bottom)**
- Native macOS **tabs** (⌘T, the tab bar's +, "Open in new tab").
- **Address bar** — ← → ↑ ⟳ buttons; breadcrumbs (`This Mac › Macintosh HD › Users › you`), each with
  a › menu of subfolders; long paths collapse into a « menu; click empty space (or ⌘L / Alt+D / F4)
  to type a path with folder **autocomplete**. Accepts `~`, relative paths, quoted paths,
  `This Mac`, and URLs. Typing a file path opens the file. Right-click Back/Forward for history.
- **Search box** — Spotlight-accelerated search across the current folder and its subfolders as you type,
  with automatic filesystem fallback for unindexed folders, hidden items, and ZIP archives; supports
  wildcards (`*.pdf`, `IMG_????.jpg`). Results show a Folder column.
- **Command bar** — New ▾ · Cut · Copy · Paste · Rename · Share · Delete · Sort ▾ · View ▾ · ⋯ · Preview · Details.
- **Navigation pane** — Home, iCloud Drive, pinned Quick access folders, This Mac › drives › folders.
  Expands to the open folder; drop files on any folder; middle-click any folder to open in a new tab.
- **Status bar** — item count, selection count and size, Details / Large icons toggles.

**Views** — Extra large, Large, Medium and Small icons, List, **Details**, Tiles and **Content**
(⌃⇧1…8, as in Explorer). **Group by** Name, Date modified, Type or Size, with collapsible Explorer groups
("Today", "Last week", "Tiny (0 – 16 KB)"…) — click a header to collapse/expand, or right-click to
collapse/expand all. Photos, videos and PDFs get thumbnails. Every folder remembers its own
layout and sort order. **This Mac** page with your folders and drives, with free-space bars.
**Preview pane** (⌥P) powered by Quick Look, and **Details pane** (⌥⇧P) showing large thumbnails,
file metadata, media dimensions/duration, and live folder size.

**Details view** — Name, Date modified, Type, Size (in KB, as Explorer shows it), Date created and
a Folder column for search results. Click headers to sort (folders stay grouped); right-click the
header to show or hide columns; drag to reorder and resize. Natural sort ("file2" before "file10").

**File operations**
- Cut / Copy / Paste through the system clipboard (Finder can paste Arbor's copies and vice versa).
  Cut items are dimmed until pasted.
- Paste into the same folder makes `name - Copy.ext`, `name - Copy (2).ext`.
- Name conflicts ask **Replace / Skip / Keep both**, with "Do this for all". A folder that already
  exists can be **merged**: everything is kept and you're only asked about files that clash.
- Drag and drop: same drive moves, other drive copies; ⌥ forces copy, ⌘ forces move.
- **New folder** / **New text document** start an inline rename, like Explorer.
- **Rename** with F2 or a slow second click; only the name is selected, not the extension. Select
  several items and rename one to get `Holiday (1).jpg`, `Holiday (2).jpg`… Changing an extension asks first.
- **Delete** moves to the Trash with no prompt; Shift+Delete deletes permanently (after asking).
  Drives without a Trash offer to delete permanently.
- **Undo / Redo** (⌘Z / ⇧⌘Z) for copy, move, rename, delete, new and compress — across all windows.
- Progress window with Cancel for long operations.
- Compress to ZIP, Extract All, Copy as path, Open with ▸, Share ▸, Open in Terminal, Show in Finder,
  Pin to Quick access, Eject, **Properties** (size on disk, contents, dates, Read-only and Hidden).

**Network** — Connect to Server (⌘K) and Map network drive for SMB, AFP, NFS, WebDAV and FTP. Type
`\\server\share` or `smb://server/share` in the address bar. Mapped servers appear under Network
locations on This Mac and can reconnect when Arbor starts.

**Open from anywhere** — an optional system-wide shortcut (⌥⌘E and others) that opens a new Arbor
window from any app, like Win+E, plus Open at login.

**Languages** — English, Simplified Chinese (简体中文), and Japanese (日本語), using Windows 11 Explorer's native terminology.

**Folder Options** (⌘, or ⋯ › Options) — a copy of Explorer's dialog, with OK / Cancel / Apply and
Restore Defaults on each tab:
- *General* — Open Arbor to (Home, This Mac, iCloud Drive…); open each folder in the same window or
  its own window; single-click to open (point to select, with underlined titles) or double-click;
  Privacy: recently used files (Go › Recent Files), frequently used folders (in the navigation pane),
  Clear history; plus an opt-in "Use Arbor to Open Folders" / "Restore Finder".
- *View* — Apply to Folders / Reset Folders, and the Advanced settings list: always show icons,
  file icon on thumbnails, size in folder tips, full path in the title bar, hidden files, hide empty
  drives, **hide extensions for known file types**, hide protected operating system files (with
  Explorer's warning), restore previous folder windows at launch, pop-up descriptions, preview
  handlers, status bar, Backspace behaviour, item check boxes, typing into the search box or
  selecting the typed item, expand to open folder, and Show This Mac.
- *Search* — include system directories, include compressed (ZIP) files, and search file contents.

Explorer options that have no macOS equivalent are left out: libraries, drive letters, NTFS
colours, the Sharing Wizard, separate processes, sync provider notifications, Office.com files and
the search index. View › Show also has Compact view, Item check boxes, File name extensions and
Hidden items, as in Explorer's View menu.

## Keyboard shortcuts

Explorer's keys work alongside the usual Mac ones (on a Mac keyboard, Alt is ⌥ and Ctrl+key is
usually ⌘+key).

| Action | Explorer key | Mac key |
| --- | --- | --- |
| Open selected item | Enter | ⌘↓ |
| Back / Forward | Alt+← / Alt+→, Backspace | ⌘[ / ⌘] |
| Up one level | Alt+↑ | ⌘↑ |
| Rename | F2 | |
| Delete (to Trash) | Delete (⌦) | ⌘⌫ |
| Delete permanently | Shift+Delete | ⌥⌘⌫ |
| Cut / Copy / Paste | | ⌘X / ⌘C / ⌘V |
| Copy as path | | ⌥⌘C |
| Undo / Redo | | ⌘Z / ⇧⌘Z |
| New folder | Ctrl+Shift+N | ⇧⌘N |
| New text document | | ⌥⌘N |
| Edit the address | Alt+D, F4 | ⌘L, ⇧⌘G |
| Search | F3 | ⌘F |
| Refresh | F5 | ⌘R |
| Properties | Alt+Enter | ⌘I |
| Preview pane | Alt+P | ⌥⌘P |
| Details pane | Alt+Shift+P | ⇧⌥⌘P |
| Quick Look | | Space, ⌘Y |
| Layouts | Ctrl+Shift+1…8 | ⌃⇧1…8 |
| Connect to Server | | ⌘K |
| New window from any app | Win+E | optional, e.g. ⌥⌘E |
| First / last item | Home / End | |
| New window / tab | | ⌘N / ⌘T |
| Close tab | | ⌘W |
| This Mac / Home | | ⇧⌘C / ⇧⌘H |
| Hidden items | | ⇧⌘. |

## Building

Requirements: macOS 14 or later, Xcode 16 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The Xcode project is generated from `project.yml`.

```bash
make run      # generate the project, build, and launch Arbor
make test     # run the unit tests
make app      # build a Release Arbor.app into build/
```

Or `xcodegen generate` and open `Arbor.xcodeproj`.

**CI.** Every push to `master` and every pull request builds Arbor, runs the unit tests and uploads
the Release `Arbor.app` as a workflow artifact (`.github/workflows/ci.yml`). Pushing a tag such as
`v0.2.0` runs `.github/workflows/release.yml`, which tests, builds that version and publishes it as a
GitHub release. Release builds are ad-hoc signed, not notarized. You can pass a folder to start in:
`build/DerivedData/Build/Products/Debug/Arbor.app/Contents/MacOS/Arbor ~/Downloads`.

Arbor is not sandboxed (a file manager needs to reach the whole disk). macOS asks for access to
Desktop, Documents, Downloads and removable drives the first time; for protected areas such as
`~/Library/Mail`, grant **Full Disk Access** in System Settings › Privacy & Security.

## Editions and releases

Arbor builds two apps from the same code:

| | Download (`Arbor` target) | Mac App Store (`Arbor App Store` target) |
| --- | --- | --- |
| Sandbox | No | Yes — asks once for your startup disk (Arbor › Grant Disk Access…) |
| Updates | Sparkle, from GitHub releases | App Store |
| Use Arbor to open folders | Yes | No (sandboxed apps can't change the default) |
| Everything else | Yes | Yes; ZIP tools, Eject and network mounting may be limited by the sandbox |

**Signed releases.** `.github/workflows/release.yml` signs, notarizes and publishes a Sparkle feed
only when these are set on the repository; without them, releases stay ad-hoc signed:

- secrets `DEVELOPER_ID_P12` (base64 of a Developer ID Application .p12), `DEVELOPER_ID_P12_PASSWORD`
- variable `SIGN_IDENTITY`, e.g. `Developer ID Application: Kitta Ltd (7P8CLHDH5G)`
- secrets `NOTARY_KEY` (App Store Connect API .p8 contents), `NOTARY_KEY_ID`, `NOTARY_ISSUER`
- secret `SPARKLE_PRIVATE_KEY` and variable `SPARKLE_PUBLIC_KEY` (from Sparkle's `generate_keys`)

`scripts/sign-and-notarize.sh` does the same locally. `scripts/appstore-upload.sh` archives and
uploads the App Store build. `packaging/homebrew/arbor.rb` is the cask for a Homebrew tap.

## Architecture

```
Arbor/
  App/        AppDelegate (windows, tabs, Explorer key monitor), MainMenu, BrowserWindowController
  Core/       Pure model, unit-tested: FileItem, Location, NavigationHistory, view settings & sorting,
              NameGenerator ("- Copy", "(2)"), Format (KB / sizes), PathResolver, Preferences
  Services/   DirectoryLoader & watcher, SearchService, VolumeService, FileClipboard,
              FileOperationService (undoable ops, conflicts, progress), thumbnails & icons
  UI/
    Browser/        BrowserViewController — one tab; owns state and runs every command
                    (+Commands, +Menus, +Delegates incl. the Explorer key map and Quick Look)
    AddressBar/     breadcrumbs, path editing with autocomplete, search box
    CommandBar/     command bar and status bar
    NavigationPane/ lazy tree with reveal-current-folder
    Content/        ItemPresenter protocol; Details table, icon grid (6 layouts), This Mac, preview
    Panels/         Properties, Folder Options, progress
ArborTests/   unit tests for the Core rules
```

Design notes:
- **One command path.** Menu bar, command bar, context menus and keys all call the same
  `BrowserViewController` actions; validation lives in one `canPerform`. Context-menu items carry
  their targets, so right-clicking a folder in the tree acts on that folder.
- **Views are swappable.** Details and the icon grid both implement `ItemPresenter`, so adding a
  layout (e.g. Explorer's "Content" view) doesn't touch the browser.
- **File changes are data.** Each `FileOp` produces a `FileChange` that knows its inverse, which
  gives Undo/Redo for every operation and a single place for conflict handling and progress.
- **Explorer keys without breaking text editing.** A key monitor handles Explorer-only keys
  (Backspace, Enter, F2, Alt+arrows…) only when you're not typing in a text field.

## Roadmap

Ideas for later: more languages, dual-pane / split-view mode, and signed, notarized
releases with automatic updates.

## License

Arbor is released under the [MIT License](LICENSE).
