# Obsidian

Obsidian is a native macOS Markdown notes app built with SwiftUI and AppKit.

It is designed as an Obsidian-compatible home for a plain-text vault, with safe local files, iCloud Drive support, fast note switching, metadata, backlinks, workflows, and preview.

## What The App Does

- Opens a notes folder as a vault
- Shows notes and folders in a sidebar
- Lets you create, edit, save, search, and delete notes
- Supports Obsidian properties, aliases, tags, wiki links, backlinks, attachments, templates, and Daily Notes
- Includes persistent tabs, pinned notes, split preview, an outline, saved searches, Bases-style views, and vault health checks
- Renders Markdown in a native preview
- Maps note relationships in a graph view
- Renders Mermaid diagrams
- Shows image files and inline image embeds
- Includes Sparkle-based app updates for shipped builds

## Main Features

### Notes And Vaults

- Open a folder and use it as your notes vault
- Automatically restore the last opened vault on launch
- Automatically restore the last selected file in that vault
- Restore open tabs, pinned notes, and split-preview state per vault
- Keep recent vaults available from the welcome screen
- Browse nested folders and notes in a sidebar
- Sort notes by date modified or by name
- Collapse all expanded folders from the sidebar footer
- Create new notes and folders from the app
- Delete notes from the sidebar
- Drag and drop a Markdown file onto the app to safely import it into the current vault
- Detect external file changes and protect unsaved edits with conflict and recovery handling
- Update incoming wiki, Markdown, and attachment links when notes or folders are renamed or moved

### Editing

- Plain-text Markdown editor with syntax highlighting
- Autosave while typing
- Formatting commands for:
  - bold
  - italic
  - inline code
  - links
  - headings
  - blockquotes
  - bullet lists
  - numbered lists
  - code blocks
- Preserves note bytes on open, including YAML frontmatter and CRLF line endings
- Sidebar titles use frontmatter titles or the first heading when available
- Supports Obsidian-style `[[Wiki Links]]` with title completion
- Shows real X post cards and YouTube videos in both editing and reading preview; standalone links and `![](YouTube URL)` use the same renderer, while links within commentary stay inline
- Shows a YouTube video's thumbnail until you click it, then loads the player and starts playing, so notes with many videos open quickly
- Reuses web views from cards that scrolled away or closed, so new cards skip WebKit's setup
- Expands tall posts to their measured height, with width-aware height caching and stable editor scrolling
- Shows retry and original-link controls for unavailable, offline, timed-out, or crashed embeds
- Pauses offscreen embeds and restores YouTube playback positions during the session; a video only plays after you click it
- Encodes and loads snapshots off the UI thread, with a 32 MB memory budget, 64 MB disk budget, and seven-day disk expiry
- Copies pasted or dropped attachments into the configured Obsidian attachment folder
- Toggle Markdown tasks with `Shift-Command-Return`

### Preview

- Toggle between source editing and rendered preview
- Native Markdown preview for normal notes
- HTML fallback preview when needed
- Mermaid diagram rendering
- Clickable links in preview
- Obsidian-style note links render as clickable internal note links in preview
- Image attachment loading relative to the current note or vault
- Direct preview for image files selected in the sidebar

### Graph View

- Switch from editor or preview into a vault graph view
- Visualizes note-to-note connections from `[[Wiki Links]]` and local markdown links
- Centers the selected note and highlights connected notes
- Click any node in the graph to open that note

### Organization And Workflows

- Inspect the current note's outline, backlinks, unlinked mentions, tags, aliases, and properties
- Convert an unlinked mention into a wiki link with one click
- Edit common frontmatter fields without rewriting the rest of the note
- Open today's Daily Note and create notes from vault templates
- Use `{{title}}`, `{{date}}`, and `{{time}}` in templates
- Browse notes in table, list, or card-based Bases views and filter by tag or property
- Scan the vault for broken links, missing attachments, duplicate note targets, malformed frontmatter, and recovery drafts

### Inline Image Editing

- Optional inline image previews while editing
- Hides the raw image embed syntax until the caret moves onto that line
- Lets you click and edit around inline image previews in the source editor

### Search

- Command palette for searching notes by title, body, file name, or relative path
- Obsidian-style filters for text, file, path, tag, property, and task state
- Quoted phrases, `OR` groups, exclusions, result snippets, and saved searches
- Incrementally maintained full-text index with cancellation-safe background filtering and lazy snippets
- Reuses parsed tags and properties across search sessions; filename, path, and task filters skip metadata parsing

### Updates

- Built-in Sparkle updater for shipped builds
- `Check for Updates…` menu item in the app
- App reads the update feed from the root [appcast.xml](appcast.xml)
- Sparkle archives are intended to be hosted in GitHub Releases, not committed into the repo
- Local installs intentionally disable Sparkle so `/Applications/Obsidian.app` does not drift from the published feed

## Keyboard Shortcuts

- `Command-N`: New file
- `Shift-Command-N`: New folder
- `Command-O`: Choose folder
- `Command-S`: Save
- `Command-B`: Show or hide sidebar
- `Command-K`: Search notes
- `Shift-Command-B`: Bold
- `Command-I`: Italic
- `Command-E`: Inline code
- `Shift-Command-K`: Link
- `Shift-Command-Return`: Toggle task

## Requirements

- macOS 15 or newer
- Xcode 16 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (CI pins 2.46.0; use the same version locally so the generated `Info.plist` matches)
- [GitHub CLI](https://cli.github.com/) for publishing updates with the release script

## Project Structure

- [Obsidian](Obsidian): app source code
- [ObsidianTests](ObsidianTests): unit tests
- [project.yml](project.yml): XcodeGen project definition
- [scripts](scripts): helper scripts, including release tooling
- [releases](releases): tracked release notes
- [appcast.xml](appcast.xml): Sparkle feed used by the app

## Run Locally

### Preferred Local Install

Use the local install script if you want the app in `/Applications` with stable local signing and Sparkle disabled:

```bash
./scripts/install_local_app.sh
```

That script will:

- create a local `Markdown` code-signing identity if needed
- generate the Xcode project
- build a local app
- install a clean `/Applications/Obsidian.app`
- back up the previous `Markdown.app` outside `/Applications`
- launch it
- blank the Sparkle feed and public key for that local build

The project, scheme, and Swift module are named `Obsidian`. The app retains the `com.md.MarkdownEditor` bundle identifier and the local `Markdown` signing identity so existing vaults, preferences, and recovery drafts continue to work. Published releases retain their original archive filenames. The installer stops if `/Applications/Obsidian.app` belongs to a different application.

The logo and app icon sources are documented in [branding](branding/README.md).

### Manual Builds

### 1. Generate The Xcode Project

```bash
xcodegen
```

### 2. Build The App

Debug build:

```bash
xcodebuild -project Obsidian.xcodeproj -scheme Obsidian -configuration Debug build
```

Release build:

```bash
xcodebuild -project Obsidian.xcodeproj -scheme Obsidian -configuration Release build
```

### Mandatory Check

Run the same documentation, dependency-resolution, build, and test gate used by
pull requests:

```bash
bash scripts/check.sh
```

The mandatory test suite runs the search benchmarks for correctness only: the
deterministic 10,000- and 50,000-note searches and the 2,000-note
advanced-filter benchmark must return the expected results, and advanced
filters also cover concurrent queries and cache invalidation after local or
external edits. A separate test runs the plain-text and advanced searches in an
already cancelled task and requires an empty result. The 10,000- and 50,000-note
benchmarks print p50 and p95 query time, the process physical footprint
(`task_vm_info` `phys_footprint`) after the run, its growth over the starting
footprint, the peak growth, and cancellation latency, and fail if the footprint
grows by more than 4 GiB. The 2,000-note advanced-filter benchmark prints only
first-run and reopen p50 and p95 times. The wall-clock limits, the 1 GiB
peak-footprint limit and the cancellation-latency limit are enforced only by
the standalone full profile, which compiles with `MARKDOWN_SEARCH_BENCHMARK_FULL`
and takes 12 samples for the larger corpora: advanced-filter reopen p95 <=
150 ms on 2,000 notes, search p95 <= 500 ms at 10,000 notes and <= 2,000 ms at
50,000 notes, cancellation <= 200 ms, and peak physical-footprint growth <=
1 GiB:

```bash
scripts/benchmark_search.sh --full
```

`DownGFM` is pinned to an exact revision in `project.yml`, and the resolved
package graph is committed so a moving branch cannot silently change a build.
`Obsidian/Info.plist` is likewise tracked but generated from `project.yml`: the
check regenerates it and fails when the committed plist is stale, so run
`xcodegen` and commit the plist together with any `project.yml` change.

`scripts/check.sh` reads two optional environment variables; both are unset by
default so local runs keep plain `xcodebuild` behavior:

- `SPM_CLONED_SOURCE_PACKAGES_DIR`: passed as `-clonedSourcePackagesDirPath`
  so CI can cache the SwiftPM checkouts, keyed on `Package.resolved`
- `XCRESULT_PATH`: an `.xcresult` path passed as `-resultBundlePath`; CI
  uploads it as a workflow artifact when the check fails

CI ([ci.yml](.github/workflows/ci.yml)) runs on pushes to `main` and on pull
requests. It sets `HOMEBREW_NO_AUTO_UPDATE=1`, installs the pinned XcodeGen
release used locally (`XCODEGEN_VERSION`, verified against a checksum), and
logs `xcodegen --version` and `xcodebuild -version` instead of pinning an
Xcode path on the runner.

### 3. Launch The Built App

The built app bundle is usually here:

```bash
~/Library/Developer/Xcode/DerivedData/Obsidian-*/Build/Products/Debug/Obsidian.app
```

or for Release:

```bash
~/Library/Developer/Xcode/DerivedData/Obsidian-*/Build/Products/Release/Obsidian.app
```

## How To Use The App

### Open Your Notes

1. Launch the app.
2. Click `Open Folder…` or press `Command-O`.
3. Choose the folder that contains your notes.

### Create A Note

1. Press `Command-N`.
2. Start typing.
3. The note autosaves while you work.

### Create A Folder

1. Press `Shift-Command-N`.

### Search Notes

1. Press `Command-K`.
2. Start typing the note name or path.
3. Press Return to open the top result.

### Preview A Note

1. Open a note.
2. Click the eye button in the toolbar to switch to preview.

### Check For Updates

1. Open the app menu.
2. Click `Check for Updates…`.

Local installs created by `./scripts/install_local_app.sh` intentionally omit this updater entry.

## Sparkle Update Flow

For users, updates come from the root [appcast.xml](appcast.xml).

For developers, the important rule is:

- the app checks the root `appcast.xml`
- release notes live in `releases/`
- heavy Sparkle archives live in GitHub Releases
- the release script keeps the root appcast in sync with those GitHub Release assets
- local `/Applications` installs should not participate in Sparkle updates

## Very Simple Release Flow

If you want to publish a new app update, do this:

### 1. Bump The Version

Edit [project.yml](project.yml):

- update `MARKETING_VERSION`
- update `CURRENT_PROJECT_VERSION`

### 2. Add Release Notes

Create this file:

```bash
releases/Obsidian-<version>.md
```

Example:

```bash
releases/Obsidian-1.0.3.md
```

### 3. Run The Release Script

```bash
SPARKLE_PRIVATE_KEY=... ./scripts/cut_release.sh
```

That command will:

- generate the Xcode project
- build the Release app
- create a local archive cache in `.release-assets/`
- generate a local appcast and delta files from that archive cache
- upload `Obsidian-<version>.zip` and the new delta files to the matching GitHub Release
- sync the root [appcast.xml](appcast.xml) that Sparkle actually reads

If your notes file is somewhere else, run:

```bash
SPARKLE_PRIVATE_KEY=... ./scripts/cut_release.sh --notes-file /path/to/release-notes.md
```

If you only want to build locally and inspect the generated appcast without publishing an update:

```bash
SPARKLE_PRIVATE_KEY=... ./scripts/cut_release.sh --skip-github-release
```

That local-only mode leaves the root [appcast.xml](appcast.xml) unchanged.

Before building, the script checks that the active `gh` account for `github.com`
(or `GH_HOST`) is signed in, downloads only the five most recent GitHub Release
archives for delta generation (Sparkle's default `--maximum-deltas`), and stops
if a GitHub Release already exists for the `MARKETING_VERSION` in `project.yml`.
Pass `--force` to replace that release instead. It skips the old assets of that
release, regenerates the deltas for the new build, and deletes the release's old
`.delta` assets before uploading the new zip and deltas:

```bash
SPARKLE_PRIVATE_KEY=... ./scripts/cut_release.sh --force
```

### 4. Commit And Push

```bash
git add project.yml releases/*.md appcast.xml
git commit -m "Release <version>"
git push origin main
```

Once `main` contains the new release notes and updated appcast, Sparkle can offer the update. The heavy archive files stay out of Git and live in GitHub Releases.

## Release Files Produced

After a release, you should expect:

- `releases/Obsidian-<version>.md`
- root [appcast.xml](appcast.xml)
- local `.release-assets/Obsidian-<version>.zip`
- GitHub Release assets for that version

## If You Only Need To Regenerate The Appcast

```bash
./scripts/generate_appcast.sh /path/to/local/archive-cache
```

If the archive URLs or notes URLs are hosted somewhere else:

```bash
./scripts/generate_appcast.sh /path/to/local/archive-cache https://your-host/releases https://your-host/releases
```

The default URLs and the appcast's project link point at
`fightingentropy/Obsidian`. Set `APPCAST_REPO=<owner/repo>` (the release
script passes its repository through automatically) or `APPCAST_LINK_URL` to
point them somewhere else.

## Notes On Keys And Signing

- Local builds intentionally leave Sparkle feed settings blank in [project.yml](project.yml)
- `./scripts/cut_release.sh` injects `SPARKLE_FEED_URL` and derives `SPARKLE_PUBLIC_ED_KEY` from `SPARKLE_PRIVATE_KEY` at release time
- If you need a non-default feed URL, set `SPARKLE_FEED_URL` when invoking the release script
- Do not commit private keys to the repo
- Use the same `SPARKLE_PRIVATE_KEY` for future releases if you want existing users to keep receiving Sparkle updates without a manual reinstall
- Local `/Applications/Obsidian.app` installs should be signed with the local `Markdown` identity, not ad-hoc
- `./scripts/create_local_codesigning_identity.sh` imports that identity's private key so only `codesign` may use it (macOS may ask once; choose Always Allow) and trusts its certificate for code signing in your login keychain only, never system-wide

### Release Signing

Release builds from `./scripts/cut_release.sh` are currently ad-hoc signed:
[project.yml](project.yml) sets no team or signing identity, so Xcode signs
the app with the `-` identity and no Developer ID. Sparkle still verifies every
archive with the EdDSA key, but Gatekeeper on macOS 15 treats a downloaded
ad-hoc app as unverified. The first launch is blocked by a dialog that only
offers Done or Move to Trash (the Control-click Open shortcut no longer
bypasses it), and the user has to open System Settings > Privacy & Security,
click Open Anyway, and confirm. Sparkle strips the quarantine attribute from
the updates it installs, so this applies to the first manual install only.

Shipping a release that opens without that detour needs credentials this
repository does not have, so nothing here enables it yet:

1. A Developer ID Application certificate from the Apple Developer Program,
   installed in the keychain of the release machine.
2. Hardened runtime and Developer ID signing for the Release configuration
   (`ENABLE_HARDENED_RUNTIME=YES`, `CODE_SIGN_IDENTITY="Developer ID
   Application"`, `DEVELOPMENT_TEAM=<team id>`), so the app and the embedded
   Sparkle framework and XPC services are signed with a secure timestamp.
3. Notarization of the zip with `xcrun notarytool submit Obsidian-<version>.zip
   --keychain-profile <profile> --wait`, after storing an App Store Connect
   API key or app-specific password once with `xcrun notarytool
   store-credentials`.
4. Stapling the ticket with `xcrun stapler staple Obsidian.app`, rebuilding the
   zip with `ditto` so the archive contains the stapled bundle, and checking
   the result with `spctl --assess --type execute -vv Obsidian.app`.
5. Keeping the same `SPARKLE_PRIVATE_KEY`: Sparkle accepts an update whose
   Apple signing identity changed as long as the embedded EdDSA public key is
   unchanged and the archive signature validates.

## Current Update Feed

Release builds should inject:

- [appcast.xml](appcast.xml)
- feed URL: `https://raw.githubusercontent.com/fightingentropy/Obsidian/main/appcast.xml`
