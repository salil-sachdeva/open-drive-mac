# Changelog

All notable changes to Open Drive for macOS will be documented in this file.

## [1.0.0] - 2026-11-14

### Added
- Native Apple `FSKit` (`FSUnaryFileSystem` / `FSVolume`) filesystem extension (`OpenDriveFS.appex`) mounting at `~/Library/Open Drive`.
- Google Drive REST API v3 client (`GoogleDriveClient`) with desktop OAuth 2.0 PKCE + localhost loopback callback listener (`GoogleOAuthLoopbackServer`).
- 6-table SQLite3 WAL metadata store (`MetadataStore`) with case-insensitive collision disambiguation (`shownAs` / `folded`).
- `4 MiB` LRU disk `ChunkCache` and coalescing `RangeReader` with sequential read-ahead prefetching.
- Client-side `FDE1` random-access chunk encryption, `FDNames` filename encryption, remote `.fd-meta` `KeyBundle` sync, and US-Letter recovery key PDF generator (`VaultCrypto`).
- Resumable `UploadEngine` with optimistic concurrency conflict naming, `NWPathMonitor` hotspot auto-pause, and bandwidth limiting.
- `OpenDriveApp` menu-bar interface with drag-and-drop upload target, `DiskArbitration` unmount guard, global `⌃⌥F` search palette, floating upload HUD pill, 3-tab Settings window, and Finder Services integration (`⌘⇧C`).
- Standalone `open-drive-mcp` JSON-RPC 2.0 `stdio` Model Context Protocol server for Claude Desktop, Cursor, and Claude Code.
