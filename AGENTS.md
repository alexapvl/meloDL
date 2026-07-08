# AGENTS.md

## Project Overview

**meloDL** is a native macOS app for downloading and converting audio from media URLs. It orchestrates bundled **yt-dlp** and **ffmpeg**/**ffprobe**, queues downloads as persisted sessions, and optionally blocks re-downloads via a local library index with duplicate review and Rekordbox-assisted matching.

Treat this as a small, single-user desktop app - prefer focused diffs, reuse existing patterns, and avoid over-engineering.

## Stack

- macOS **15.5+**, **Swift 6** + **SwiftUI** + AppKit (menu bar, notifications)
- **Sparkle** (SwiftPM) for app auto-updates via `appcast.xml`
- **SQLite3** (raw C API) for download sessions and duplicate index
- **yt-dlp**, **ffmpeg**, **ffprobe** - bundled in Resources, copied to `~/Library/Application Support/meloDL/bin/`
- **CryptoKit** for content hashing during library indexing
- Bundle ID: `com.alexapvl.meloDL`

Commands:

```bash
open meloDL.xcodeproj

./scripts/build-release.sh              # signed DMG
./scripts/build-release.sh --notarize   # + notarytool + stapling

sparkle/bin/generate_appcast build/      # after release DMG in build/
```

Release script refreshes bundled `meloDL/yt-dlp` from GitHub latest before archiving.

## Project Structure

```
meloDL/
  App/                    @main app, menu bar controller, lifecycle
  Models/                 AppSettings, DownloadSession, AudioSettings, DuplicateMatch
  ViewModels/             DownloadSessionCoordinator, IndexingSettingsViewModel
  Views/                  ContentView, SettingsView, OnboardingView, Components/
  Services/               DownloadEngine, BinaryManager, stores, indexing, updates
  Utilities/              Extensions
scripts/                  build-release.sh, helper-binary.entitlements
appcast.xml               Sparkle update feed
```

## Architecture

### Download pipeline (`DownloadEngine.swift`)

- Runs **yt-dlp** via `Process`; `--ffmpeg-location` from `BinaryManager`
- Single URLs and playlists; playlists prefetched with `--flat-playlist`
- Emits `DownloadEvent` through `AsyncThrowingStream`; cancellation via `ProcessRegistry`

### Binary lifecycle (`BinaryManager.swift`)

- Runtime binaries in `~/Library/Application Support/meloDL/bin/`
- First launch seeds from bundle; versions in `versions.json`
- `GitHubUpdateService` updates yt-dlp and ffmpeg-static releases in Application Support

### Sessions (`DownloadSessionCoordinator.swift`)

- URLs → `DownloadSession` rows in SQLite (`DownloadSessionStore`)
- Parallelism capped by `AppSettings.maxParallelSessions`
- States: active download, duplicate review (`waitingForUser`), failure, cancellation

### Library index & duplicates

| Component | Role |
|-----------|------|
| `TrackIndexStore` | `duplicate-index.sqlite`; normalized titles, durations, content hashes |
| `TrackIndexer` | Background reindex of configured roots |
| `DuplicateDetectionService` | Title/token similarity before download |
| `RekordboxLibraryStore` | XML import for DJ library cross-reference |
| `DuplicateReviewModal` | Staged cleanup with post-action undo window |

### App updates (Sparkle)

- `MARKETING_VERSION` = user-facing version; `CURRENT_PROJECT_VERSION` = Sparkle build - **never reset build to 1**
- Each release: signed/notarized DMG on GitHub Releases + `appcast.xml` entry with `sparkle:edSignature`
- Full release workflow: **mac-app-release** skill (`publish_release.sh melodl <version>`)

### UI modes

- `LSUIElement` = true; optional **menubar-only** via `AppSettings` / `--menubar-only`
- Settings is an in-window page (`SettingsView`), not a separate Settings scene

## Conventions

- **MainActor**: app entry, `AppSettings`, `DownloadSessionCoordinator`, SwiftUI views
- **Actors**: `BinaryManager`, SQLite stores, `TrackIndexer` - use `await` at boundaries
- **Settings**: `UserDefaults` keys in model `Keys` enums; `@Published` with `didSet` persistence
- **Logging**: `os.Logger` subsystem `com.alexapvl.meloDL`
- **Schema**: additive SQLite migrations inside store `migrate()` - no destructive one-offs unless requested

## What To Avoid

- Committing signing credentials, notary profiles, or private keys
- Resetting `CURRENT_PROJECT_VERSION` / Sparkle build numbers
- Invoking yt-dlp/ffmpeg outside `DownloadEngine` / `BinaryManager`
- Broad refactors or new abstractions for one-off fixes
- Committing unless the user asks
- Editing `README.md`, `PRIVACY.md`, or docs unless requested

## Verification

```bash
xcodebuild -project meloDL.xcodeproj -scheme meloDL -configuration Debug build -quiet
```

Manually: single download, playlist queue, duplicate detection/review, menubar-only relaunch, Settings update checks.
