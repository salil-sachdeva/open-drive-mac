import AppKit
import DiskArbitration
import Foundation
import OpenDriveCore

/// Manages mounting/unmounting the FSKit volume at `~/Library/Open Drive` and guards against
/// premature ejection while uploads are in flight (`DiskArbitration`).
@MainActor
public final class MountManager: ObservableObject {
    @Published public private(set) var isMounted: Bool = false
    @Published public private(set) var lastMountMessage: String = "Checking mount state..."

    private var daSession: DASession?

    public init() {
        refreshMountState()
        setupWorkspaceMountNotifications()
        setupDiskArbitrationEjectGuard()
    }

    public func refreshMountState() {
        let mountPath = OpenDrivePaths.mountRootURL.path
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let mounted = output.contains(mountPath)
            self.isMounted = mounted
            self.lastMountMessage = mounted
                ? "Mounted at \(mountPath)"
                : "Not mounted (\(mountPath))"
        } catch {
            self.isMounted = false
            self.lastMountMessage = "Ready to mount at \(mountPath)"
        }
    }

    public func mountFilesystem() {
        let mountURL = OpenDrivePaths.mountRootURL
        do {
            try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/sbin/mount")
            proc.arguments = ["-t", OpenDrivePaths.fsShortName, "opendrive", mountURL.path]

            let pipe = Pipe()
            proc.standardError = pipe
            proc.standardOutput = pipe
            try proc.run()
            proc.waitUntilExit()

            if proc.terminationStatus == 0 {
                isMounted = true
                lastMountMessage = "Mounted at \(mountURL.path)"
            } else {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                lastMountMessage = "Mount exited (\(proc.terminationStatus)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        } catch {
            lastMountMessage = "Mount failed: \(error.localizedDescription)"
        }
    }

    public func unmountFilesystem(force: Bool = false) {
        let mountURL = OpenDrivePaths.mountRootURL
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/umount")
        proc.arguments = force ? ["-f", mountURL.path] : [mountURL.path]
        try? proc.run()
        proc.waitUntilExit()
        refreshMountState()
    }

    private func setupWorkspaceMountNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshMountState()
            }
        }
        center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshMountState()
            }
        }
    }

    private func setupDiskArbitrationEjectGuard() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.daSession = session
        DASessionSetDispatchQueue(session, DispatchQueue.global(qos: .userInitiated))

        let callback: DADiskUnmountApprovalCallback = { disk, _ in
            guard let desc = DADiskCopyDescription(disk) as? [String: Any],
                  let volumePathURL = desc[kDADiskDescriptionVolumePathKey as String] as? URL else {
                return nil
            }
            let targetPath = OpenDrivePaths.mountRootURL.standardizedFileURL.path
            guard volumePathURL.standardizedFileURL.path == targetPath else {
                return nil
            }

            if MountManager.hasActiveUploadsSync() {
                DarwinNotifier.shared.post(.ejectGuard)
                let dissenter = DADissenterCreate(
                    kCFAllocatorDefault,
                    DAReturn(kDAReturnBusy),
                    "Open Drive is still uploading files to Google Drive." as CFString
                )
                return Unmanaged.passRetained(dissenter)
            }
            return nil
        }

        DARegisterDiskUnmountApprovalCallback(session, nil, callback, nil)
    }

    nonisolated public static func hasActiveUploadsSync() -> Bool {
        let regURL = OpenDrivePaths.accountsRegistryURL
        guard let data = try? Data(contentsOf: regURL),
              let accounts = try? JSONDecoder().decode([CloudAccount].self, from: data) else {
            return false
        }
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var value = false }
        let box = Box()
        Task {
            for acc in accounts {
                if let store = try? MetadataStore(databaseURL: OpenDrivePaths.databaseURL(for: acc.id)),
                   let pending = try? await store.fetchPendingUploads(),
                   !pending.isEmpty {
                    box.value = true
                    break
                }
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1.5)
        return box.value
    }
}
