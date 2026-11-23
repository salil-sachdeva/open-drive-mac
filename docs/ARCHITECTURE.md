# Open Drive Architecture

Open Drive is organized into three Swift Package Manager targets that communicate through an SQLite3 WAL store (`~/Library/Application Support/OpenDrive/db/<accountId>.sqlite`), macOS Keychain, and Darwin notifications (`CFNotificationCenterGetDarwinNotifyCenter`).

## Target Overview

| Target | Product | Role |
| :--- | :--- | :--- |
| `OpenDriveCore` | Library | Shared VFS engine (`DriveVolume`), SQLite WAL store (`MetadataStore`), `4 MiB` `ChunkCache` & `RangeReader`, `ODE1` `VaultCrypto`, `UploadEngine`, `SyncEngine`, and `GoogleDriveClient`. |
| `OpenDriveFS` | `OpenDriveFS.appex` | Apple `FSKit` (`FSUnaryFileSystem` / `FSVolume`) user-space filesystem extension mounted at `~/Library/Open Drive`. |
| `OpenDriveApp` | `Open Drive.app` | Menu-bar host app (`MenuBarExtra`), 3-tab Settings window, `DiskArbitration` eject guard, global `⌃⌥F` search palette, floating upload HUD pill, and Finder Services (`NSServices`). |

---

## Data Flow

### 1. Read Path (`FSKit` → `DriveVolume` → `RangeReader` → `ChunkCache` → `GoogleDriveClient`)
1. Finder or a POSIX process issues a read against `~/Library/Open Drive/<Account>/<File>`.
2. `OpenDriveVolume.read(...)` forwards the `(itemId, offset, length)` request to the `DriveVolume` actor.
3. If the file has a dirty local `ScratchBuffer`, reads are served directly from `~/Library/Caches/OpenDrive/tmp/`.
4. Otherwise, `RangeReader` maps the byte range into `4 MiB` `ChunkKey(driveId, version, chunkIndex)` blocks, coalesces concurrent requests for the same chunk, and prefetches the next chunk when 2 consecutive chunks are read sequentially.
5. Encrypted files (`isEncrypted == true`) have their 72-byte `ODE1` header unwrapped once via the account's Master Key (`MK`) and each `4 MiB + 16 B` wire chunk authenticated and decrypted in random-access order via `AES-256-GCM`.

### 2. Write & Upload Path (`ScratchBuffer` → `UploadEngine` → `GoogleDriveClient`)
1. Writes land in a local `ScratchBuffer` file (`~/Library/Caches/OpenDrive/tmp/`).
2. On `closeItem`, `DriveVolume.closeAndCommitIfDirty` enqueues an `UploadRecord` in `MetadataStore.uploads` with `baseVersion` and `baseHash`.
3. `UploadEngine` checks whether the remote file changed since `baseVersion`; if a conflict is detected, the local file is renamed using `ConflictName.make(for:)` so neither version is lost.
4. `UploadEngine` streams `4 MiB` resumable chunks (`HTTP PUT` / `308 Resume Incomplete`), automatically pausing when `NetworkPathObserver` detects a Personal Hotspot (`isExpensive` / `isConstrained`) or offline state.

### 3. Delta Sync & Local Change Protection (`SyncEngine`)
1. `SyncEngine` hydrates the root directory on initial setup and hydrates subfolders on demand (`hydrateFolderIfNeeded`).
2. Every 30 seconds (or immediately when `.od-refresh` is created or `DarwinSignal.signal` fires), `SyncEngine.pullRemoteChanges` polls Google Drive's `changes.list` feed (`changesPageToken`).
3. Any `driveId` recorded in `MetadataStore.localChanges` within the last 10 seconds is skipped during delta reconciliation to prevent stale remote change events from overwriting just-committed local edits.
