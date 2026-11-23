# Open Drive for macOS

An open-source macOS cloud filesystem mounter built natively in Swift on **Apple's `FSKit.framework`** (`FSUnaryFileSystem` / `FSVolume`). Open Drive mounts your Google Drive accounts directly at `~/Library/Open Drive` with on-demand `4 MiB` chunk streaming and optional zero-knowledge client-side encryption (`ODE1`).

---

## Features

- **Native Apple `FSKit` User-Space Filesystem (`OpenDriveFS.appex`)** — Zero kernel extensions (`kext`). Mounts directly at `~/Library/Open Drive` via `/sbin/mount -t opendrive`.
- **Coalescing `4 MiB` Range Reader & Disk LRU Cache** — Streams byte ranges on demand with in-flight request deduplication, sequential read-ahead prefetching, and bounded local disk caching (`~/Library/Caches/OpenDrive/chunks`).
- **Zero-Knowledge Client-Side Vault (`ODE1` + `ODNames`)** — Optional per-file `AES-256-GCM` chunk encryption (`4 MiB` random-access chunks + deterministic 12-byte nonces), `HKDF-SHA256` filename encryption, `PBKDF2-HMAC-SHA256` passphrase key wrapping (`.od-meta`), and a printable 24-word recovery key sheet (`open drive recovery key.pdf`).
- **Resumable Upload Engine & Optimistic Concurrency** — Background chunked uploads with `NWPathMonitor` Personal Hotspot auto-pause, configurable bandwidth cap, `DiskArbitration` unmount protection while uploads are active, and automatic conflict copy preservation (`<stem> (conflict from yyyy-MM-dd HH.mm).<ext>`).
- **Spotlight-Style Global Command Palette (`⌃⌥F`) & Floating HUD Pill** — Instant sub-millisecond search across all connected Google Drives, offline file pinning, drag-and-drop menu-bar upload target, and macOS Finder Services (`⌘⇧C`).

---

## Repository Structure

```text
open-drive-mac/
├── Package.swift
├── Makefile
├── Config/
│   ├── OpenDriveApp-Info.plist
│   ├── OpenDriveApp.entitlements
│   ├── OpenDriveFS-Info.plist
│   └── OpenDriveFS.entitlements
├── Scripts/
│   ├── bundle-app.sh              # Builds & signs dist/Open Drive.app + OpenDriveFS.appex
│   └── create-dmg.sh              # Packages dist/OpenDrive.dmg
├── Sources/
│   ├── OpenDriveCore/             # Shared core framework
│   │   ├── Cache/                 # ChunkCache & RangeReader
│   │   ├── Crypto/                # VaultCrypto (ODE1), KeyBundle (.od-meta), RecoveryKeyPDF
│   │   ├── IPC/                   # DarwinNotifier cross-process signal bus
│   │   ├── Models/                # Domain models & OpenDrivePaths
│   │   ├── Providers/             # CloudDrive protocol & GoogleDriveClient + OAuth 2.0 PKCE
│   │   ├── Storage/               # 6-table SQLite3 WAL MetadataStore & KeychainStore
│   │   ├── Sync/                  # UploadEngine, SyncEngine & NetworkPathObserver
│   │   └── Volume/                # DriveVolume virtual filesystem actor
│   ├── OpenDriveFS/               # Apple FSKit App Extension (OpenDriveFS.appex)
│   └── OpenDriveApp/              # macOS Menu-Bar App, Settings, Palette (⌃⌥F) & HUD Pill
├── Tests/
│   └── OpenDriveCoreTests/        # Unit & integration test suite
└── docs/
    ├── ARCHITECTURE.md            # Detailed architecture & data-flow documentation
    └── PRD.md                     # Product Requirements Document & release roadmap
```

---

## Quick Start

### 1. Requirements
- **macOS 15.4+** (Sequoia or newer with `FSKit.framework`)
- **Xcode 16.3+** / Swift 6 toolchain

### 2. Google Cloud OAuth 2.0 Client ID Setup
1. Open the [Google Cloud Console](https://console.cloud.google.com/) and create or select a project.
2. Enable the **Google Drive API** under *APIs & Services → Library*.
3. Under *APIs & Services → Credentials*, click **Create Credentials → OAuth client ID** and choose **Desktop app**.
4. Copy the generated **Client ID** (and optional Client Secret) into **Open Drive → Settings (`⌘,`) → Accounts & Vault**.

### 3. Build, Test & Bundle
```bash
# Run all unit and integration tests
make test

# Build and ad-hoc sign 'dist/Open Drive.app' (including OpenDriveFS.appex)
make app

# Optional: Package a distributable disk image at 'dist/OpenDrive.dmg'
make dmg
```

---

## Documentation & Policies

- [Product Requirements Document (PRD)](docs/PRD.md)
- [Architecture & Data Flow](docs/ARCHITECTURE.md)
- [Contributing Guidelines](CONTRIBUTING.md)
- [Security Policy & Cryptographic Design](SECURITY.md)
- [Changelog](CHANGELOG.md)
- [MIT License](LICENSE)
