# Changelog

All notable changes to Open Drive for macOS will be documented in this file.

## [1.0.0] - 2026-11-23

### Added
- Loopback Virtual Disk (`LocalNFSServer` NFSv3/MOUNTv3 + `LocalWebDAVServer` Class 2 WebDAV + RFC 6761 `*.localhost` mDNS) mounting at `~/Library/OpenDrive/<Drive Name>` with accurate multi-terabyte Google Drive free space in Finder and `Zero bytes on disk` for remote files.
- Direct Finder Favourites sidebar pinning (`FinderSidebarManager`) and live mounted volume & per-account folder renaming.
- Native Apple `FSKit` (`OpenDriveFS.appex`) and `FileProvider` (`OpenDriveFileProvider.appex`) extensions.
- Google Drive REST API v3 client (`GoogleDriveClient`) with desktop OAuth 2.0 PKCE + localhost loopback callback listener (`GoogleOAuthLoopbackServer`).
- 6-table SQLite3 WAL metadata store (`MetadataStore`) with case-insensitive collision disambiguation (`shownAs` / `folded`), POSIX symlinks, executable bit persistence, and in-memory AppleDouble (`._*`) isolation.
- Two-tier Hot/Cold `4 MiB` LRU disk `ChunkCache` and coalescing `RangeReader` with sequential read-ahead prefetching.
- Client-side `ODE1` random-access chunk encryption, `ODNames` filename encryption, remote `.od-meta` `KeyBundle` sync, and US-Letter recovery key PDF generator (`VaultCrypto`).
- Resumable `UploadEngine` with optimistic concurrency conflict naming, `NWPathMonitor` hotspot auto-pause, and bandwidth limiting.
- `OpenDriveApp` main window & menu-bar interface with drag-and-drop upload target, `DiskArbitration` unmount guard, global `⌃⌥F` search palette, floating upload HUD pill, 3-tab Settings window, Finder Services integration (`⌘⇧C`), and Liquid Glass `AppIcon.icon`.
