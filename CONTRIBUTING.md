# Contributing to `open-drive-mac`

Thank you for contributing to `open-drive-mac`!

## Development Prerequisites

* **macOS 15.4+** (or macOS 26+) with **Xcode 16.4+ / Swift 6.0+** for `FSKit.framework` support.

## Building & Running Tests

```bash
# Build all targets (OpenDriveCore, OpenDriveFS, OpenDriveApp)
swift build

# Run the unit & integration test suite
swift test

# Assemble & ad-hoc sign the macOS application bundle
./Scripts/bundle-app.sh

# Package a distributable DMG
./Scripts/create-dmg.sh
```

## Project Layout

* `Sources/OpenDriveCore` — Shared core library (SQLite3 WAL `MetadataStore`, `ChunkCache`, `RangeReader`, `GoogleDriveClient`, `GoogleOAuthLoopbackServer`, `UploadEngine`, `SyncEngine`, `VaultCrypto`, `DriveVolume`, `KeychainStore`, `DarwinNotifier`).
* `Sources/OpenDriveFS` — Apple `FSKit` App Extension (`UnaryFileSystemExtension`, `FSUnaryFileSystem`, `FSVolume`).
* `Sources/OpenDriveApp` — Menu-bar SwiftUI/AppKit host app (`MenuBarExtra`, `⌃⌥F` global search panel, floating upload HUD pill, `DiskArbitration` eject guard, Finder Services, and multi-tab Settings).
* `Tests/OpenDriveCoreTests` — Automated unit and integration tests.
