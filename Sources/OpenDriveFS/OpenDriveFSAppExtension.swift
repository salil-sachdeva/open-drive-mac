import ExtensionFoundation
import Foundation
import FSKit
import OpenDriveCore

// MARK: - FSKit App Extension Entry Point

@available(macOS 15.4, *)
@main
struct OpenDriveFSAppExtension: UnaryFileSystemExtension {
    let fileSystem = OpenDriveFileSystem()
}

// MARK: - FSUnaryFileSystem (`OpenDriveFileSystem`)

@available(macOS 15.4, *)
public final class OpenDriveFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, @unchecked Sendable {
    public override init() {
        super.init()
    }

    public func didFinishLoading() {
        DarwinNotifier.shared.observe(.clearCache) {
            Task {
                let cache = try? ChunkCache()
                await cache?.clearAll()
            }
        }
    }

    public func probeResource(
        resource: FSResource,
        replyHandler reply: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        let containerId = FSContainerIdentifier(uuid: UUID())
        let result = FSProbeResult.usable(name: "Open Drive", containerID: containerId)
        reply(result, nil)
    }

    public func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        Task {
            do {
                let volumeId = FSVolume.Identifier(uuid: UUID())
                let volumeName = FSFileName(string: "Open Drive")
                let dv = try DriveVolume()
                let volume = OpenDriveVolume(volumeID: volumeId, volumeName: volumeName, driveVolume: dv)
                await volume.bootstrapAccounts()
                reply(volume, nil)
            } catch {
                reply(nil, error)
            }
        }
    }

    public func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        reply(nil)
    }
}
