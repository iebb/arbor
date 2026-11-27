# Arbor — notes for agents and contributors

Arbor is a native macOS (Swift + AppKit, no SwiftUI) file manager that recreates the Windows File
Explorer experience. `README.md` is the user-facing feature list; this file is the working context:
how the code is laid out, how to build/test/release, decisions already made, and what's unfinished.

## Ground rules from the maintainer

- Commit directly on `master` (the default branch). No pull requests. Push only when asked.
- Commit messages are plain prose; **no `Co-Authored-By` or other AI attribution trailers**.
- Tagging `vX.Y.Z` publishes a public, signed release — only when the maintainer asks.
- The repo is public (MIT). Never commit secrets, local paths or key IDs.

## Build, run, test

Requires Xcode 16+ (developed on Xcode 27.2; CI uses the runner's Xcode 26.x) and XcodeGen.
`Arbor.xcodeproj` is generated from `project.yml` and git-ignored — **run `xcodegen generate` after
adding or removing a source file**, or the new file won't compile.

```bash
make run        # xcodegen + Debug build + open
make test       # unit tests (ArborTests, ~40 tests, all in ArborTests/ArborTests.swift)
xcodebuild -project Arbor.xcodeproj -scheme "Arbor App Store" -configuration Release build
build/DerivedData/Build/Products/Debug/Arbor.app/Contents/MacOS/Arbor /some/folder   # open at a folder
```

Pass `-AppleLanguages "(ja)"` to run in Japanese. Clean builds must have zero warnings.

Checking UI changes: launch the app and drive it with `osascript` (System Events key codes) and
`screencapture -l <windowID>`. Gotchas: with a Japanese input source active, `keystroke` text may not
reach fields; ⌘, works as `key code 43 using {command down}`; NSAlerts are separate windows; reset any
`defaults write io.github.iebb.arbor …` you set while testing.

## Layout

```
Arbor/App/        AppDelegate (windows/tabs, Explorer key monitor, launch), MainMenu, BrowserWindowController
Arbor/Core/       Pure, unit-tested model: FileItem, Location (+ FileManager.realHomeDirectory),
                  NavigationHistory, ViewSettings (view modes, sort, GroupKey + FileGrouping),
                  NameGenerator, Format, PathResolver, Preferences (FolderOption enum = every Folder
                  Options setting), FolderViewStore (per-folder layout), RecentItems
Arbor/Services/   DirectoryServices (loader, watcher, search, volumes, ProtectedFiles), FileOperations
                  (FileOp/FileChange/engine), FileOperationService (undo, progress, conflict dialogs),
                  TransferPlanner (copy/move/merge planning), FileClipboard, ThumbnailProvider,
                  NetworkLocations (NetFS mounting, mapped drives), GlobalHotKey (+ LoginItem),
                  Distribution (Edition, SandboxAccess, Sparkle Updater)
Arbor/UI/Browser/ BrowserViewController = one tab; +Commands (every action + validation), +Menus,
                  +Delegates (Explorer key map, Quick Look, address/command bar, tree, This Mac)
Arbor/UI/…        AddressBar, CommandBar (+ status bar), NavigationPane (lazy tree), Content
                  (ItemPresenter protocol; Details table; icon grid for the other 7 layouts; This Mac;
                  preview pane), Panels (Properties, Folder Options, progress)
Arbor/Resources/  Assets, ja.lproj/Localizable.strings, ArborAppStore.entitlements
scripts/          make-icon.swift, sign-and-notarize.sh, appstore-upload.sh
packaging/        homebrew/arbor.rb (cask template)
```

## Design decisions to keep

- **One command path.** Menu bar, command bar, context menus and keys all call `BrowserViewController`
  actions; enablement lives in `canPerform`. Context-menu items carry target URLs in `representedObject`.
- **Views are swappable** behind `ItemPresenter`. Details uses table rows with group-header rows;
  the icon grid uses collection-view sections whose flat `items` array is in *group order*.
- **File changes are data.** Every `FileOp` yields a `FileChange` with an inverse → app-wide undo/redo.
  `TransferPlanner` is pure (questions go through closures) so merge/conflict logic is unit-tested.
  Folder merge asks only for the top folder; nested folders merge silently, as in Explorer.
- **Explorer keys** are handled by an app-level key monitor only when no text field is editing.
- **Settings** are `FolderOption` cases (raw value = UserDefaults key). Folder Options edits a draft
  and applies on OK/Apply. Option changes post `.arborPreferencesChanged`.
- **Never use `homeDirectoryForCurrentUser` or `urls(for:in: .userDomainMask)` directly** — in the
  sandboxed build they point into the app container. Use `FileManager.realHomeDirectory` and
  `userFolderURL(_:)`.
- **Localization:** wrap every visible string in `String(localized:)` and add it to
  `Arbor/Resources/ja.lproj/Localizable.strings`. Keys use `%@` for String values and `%lld` for
  integers (match what Swift generates); reorder with `%1$@`. Japanese follows Windows 11 Explorer's
  Japanese wording (新規作成, 切り取り, 貼り付け, 一覧, フォルダー オプション…).

## Two editions

| | `Arbor` target → `Arbor.app` | `Arbor App Store` target → `ArborAppStore.app` |
| --- | --- | --- |
| Distribution | GitHub releases, notarized | Mac App Store |
| Sandbox | no | yes; asks once for a disk, kept as a security-scoped bookmark (`SandboxAccess`) |
| Updates | Sparkle (only if built with `SPARKLE_PUBLIC_KEY`) | App Store; Sparkle not linked |
| Compile flag | — | `APPSTORE` (`Edition.isAppStore`) |

Both share bundle ID `io.github.iebb.arbor` and display name "Arbor". The store target has a
different *product* name on purpose: when both were `Arbor.app`, Xcode 26's test runner launched the
store build as the unit-test host and CI failed with "Could not launch ArborTests … no such file".
`ArborTests` sets `TEST_HOST` explicitly.

## Releases and signing

- Signing team: **Kitta Ltd (7P8CLHDH5G)**, using its existing *Developer ID Application* certificate.
  The private key and the App Store Connect API key live only on the maintainer's Mac and in GitHub
  secrets.
- `.github/workflows/ci.yml`: every push/PR runs the tests and builds both editions.
- `.github/workflows/release.yml`: on a `v*` tag, it tests, builds with `MARKETING_VERSION` from the tag,
  then (if the secrets exist) signs, notarizes, staples, signs the zip for Sparkle and publishes
  `Arbor-X.Y.Z.zip`, `.sha256` and `appcast.xml`. Without secrets it falls back to ad-hoc builds.
- Repository secrets: `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_KEY`, `NOTARY_KEY_ID`,
  `NOTARY_ISSUER`, `SPARKLE_PRIVATE_KEY`. Variables: `SIGN_IDENTITY`, `SPARKLE_PUBLIC_KEY`.
- Sparkle feed: `https://github.com/iebb/arbor/releases/latest/download/appcast.xml`. The Sparkle
  private key is also in the maintainer's login keychain (account `io.github.iebb.arbor`); losing it
  means existing installs can't verify future updates.
- `scripts/sign-and-notarize.sh` reproduces the signing locally (it was verified: Apple accepted the
  notarization and Gatekeeper reports "Notarized Developer ID").
- On Kitta's App Store Connect account the bundle ID is registered and a Mac App Store profile named
  "Arbor Mac App Store" exists.

## Open work

1. **App Store:** the App Store Connect app record does not exist yet (the maintainer creates it).
   `scripts/appstore-upload.sh` has never been run. Before submitting, test in the sandboxed build:
   ZIP compress/extract (spawns `/usr/bin/ditto`/`zip`), Eject, and NetFS mounting.
2. **Homebrew:** fill `version`/`sha256` in `packaging/homebrew/arbor.rb` from a notarized release and
   publish it to a tap repo (e.g. `iebb/homebrew-tap`), which doesn't exist yet.
3. **Never tested by hand:** drag and drop (within Arbor and with Finder), right-click menus,
   Properties window, mounting a real SMB/AFP share, Sparkle updating from one signed release to the next.
4. Roadmap ideas (README): Spotlight-backed search, collapsible groups, more languages.
