import CoreServices
import Darwin
import Foundation
import OpenDriveCore

private typealias LSSharedFileListInsertItemURLFn = @convention(c) (
    UnsafeMutableRawPointer,
    UnsafeMutableRawPointer,
    CFString?,
    UnsafeMutableRawPointer?,
    CFURL,
    CFDictionary?,
    CFArray?
) -> UnsafeMutableRawPointer?

/// Pins the active Open Drive mount folder in Finder's Sidebar (**Favourites**)
/// so clicking it opens Google Drive's files directly in one click, and cleans up
/// stale/renamed Open Drive entries without touching any other user favourites.
enum FinderSidebarManager {
    private static let lastPinnedSidebarNameKey = "org.opendrive.lastPinnedSidebarName"

    static func pinInSidebar(url: URL, displayName: String) -> Bool {
        removeOpenDriveItemsFromSidebar()

        guard let list = LSSharedFileListCreate(
            nil,
            kLSSharedFileListFavoriteItems.takeUnretainedValue(),
            nil
        )?.takeRetainedValue() else {
            return false
        }

        // Resolve via dlsym so kLSSharedFileListItemLast (sentinel pointer 0x2) is passed raw
        // without Swift's Unmanaged.takeUnretainedValue() trying to objc_retain(0x2).
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "LSSharedFileListInsertItemURL") else {
            return false
        }
        let insertFn = unsafeBitCast(sym, to: LSSharedFileListInsertItemURLFn.self)
        guard let rawInserted = insertFn(
            Unmanaged.passUnretained(list).toOpaque(),
            kLSSharedFileListItemLast.toOpaque(),
            displayName as CFString,
            nil,
            url as CFURL,
            nil,
            nil
        ) else {
            return false
        }
        _ = Unmanaged<LSSharedFileListItem>.fromOpaque(rawInserted).takeRetainedValue()
        UserDefaults.standard.set(displayName, forKey: lastPinnedSidebarNameKey)

        let targetPath = url.standardizedFileURL.path
        for attempt in 0..<5 {
            if snapshotContains(list: list, targetPath: targetPath, displayName: displayName) {
                return true
            }
            if attempt < 4 {
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
        return false
    }

    static func removeOpenDriveItemsFromSidebar() {
        guard let list = LSSharedFileListCreate(
            nil,
            kLSSharedFileListFavoriteItems.takeUnretainedValue(),
            nil
        )?.takeRetainedValue() else {
            return
        }

        var seed: UInt32 = 0
        let snapshot = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem] ?? []
        let trackedName = UserDefaults.standard.string(forKey: lastPinnedSidebarNameKey)
        let resolveFlags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)

        for item in snapshot {
            let resolvedURL = LSSharedFileListItemCopyResolvedURL(item, resolveFlags, nil)?.takeRetainedValue() as URL?
            let itemName = LSSharedFileListItemCopyDisplayName(item).takeRetainedValue() as String

            let matchesManagedPath = resolvedURL.map(isManagedMountURL) ?? false
            let matchesTrackedUnresolved = (resolvedURL == nil && trackedName != nil && itemName == trackedName)
            if matchesManagedPath || matchesTrackedUnresolved {
                LSSharedFileListItemRemove(list, item)
            }
        }
        UserDefaults.standard.removeObject(forKey: lastPinnedSidebarNameKey)
    }

    private static func snapshotContains(list: LSSharedFileList, targetPath: String, displayName: String) -> Bool {
        var seed: UInt32 = 0
        let snapshot = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem] ?? []
        let resolveFlags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)

        for item in snapshot {
            if let url = LSSharedFileListItemCopyResolvedURL(item, resolveFlags, nil)?.takeRetainedValue() as URL?,
               url.standardizedFileURL.path == targetPath {
                return true
            }
            let itemName = LSSharedFileListItemCopyDisplayName(item).takeRetainedValue() as String
            if itemName == displayName {
                if let url = LSSharedFileListItemCopyResolvedURL(item, resolveFlags, nil)?.takeRetainedValue() as URL? {
                    if isManagedMountURL(url) {
                        return true
                    }
                } else {
                    return true
                }
            }
        }
        return false
    }

    private static func isManagedMountURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let legacyPath = OpenDrivePaths.legacyMountRootURL.standardizedFileURL.path
        let containerPrefix = OpenDrivePaths.mountsContainerURL.standardizedFileURL.path + "/"
        return path == legacyPath || path.hasPrefix(containerPrefix)
    }
}
