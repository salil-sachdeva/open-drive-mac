import AppKit
import DiskArbitration
@preconcurrency import FileProvider
import Foundation
import OpenDriveCore

/// Manages mounting/unmounting Open Drive via macOS local NFSv3 virtual disk
/// (reporting real Google Drive space in Finder), Apple File Provider (`~/Library/CloudStorage`),
/// or Apple FSKit when provisioned, and guards against premature ejection during uploads.
@MainActor
public final class MountManager: ObservableObject {
    @Published public private(set) var isMounted: Bool = false
    @Published public private(set) var isMountInProgress: Bool = false
    @Published public private(set) var activeBackend: String = ""
    @Published public private(set) var activeMountURL: URL = OpenDrivePaths.mountRootURL
    @Published public private(set) var lastMountMessage: String = "Checking mount state..."

    private let skipSystemChecks: Bool
    private var daSession: DASession?
    private var driveVolume: DriveVolume?
    private var chunkCache: ChunkCache?
    private var webDAVServer: LocalWebDAVServer?
    private var nfsServer: LocalNFSServer?
    private var mdnsRegistrar: LocalMDNSRegistrar?
    private var mountedNFSPath: String?
    private var activeFileProviderDomain: NSFileProviderDomain?

    public init(skipSystemChecks: Bool = false) {
        self.skipSystemChecks = skipSystemChecks
        if skipSystemChecks {
            self.isMounted = true
            self.activeBackend = "Sample Preview"
            self.activeMountURL = OpenDrivePaths.mountRootURL
            self.lastMountMessage = "Mounted in Finder Locations (Sample Preview)"
            return
        }
        refreshMountState()
        setupWorkspaceMountNotifications()
        setupDiskArbitrationEjectGuard()
    }

    public func signalFileProviderRefresh() {
        guard !skipSystemChecks,
              let domain = activeFileProviderDomain,
              let manager = NSFileProviderManager(for: domain) else {
            return
        }
        let dv = driveVolume
        Task {
            await dv?.refreshStorageQuotas()
            await dv?.bumpBridgeSyncEpoch()
            try? await manager.signalEnumerator(for: .rootContainer)
            try? await manager.signalEnumerator(for: .workingSet)
        }
    }

    public func refreshMountState() {
        guard !skipSystemChecks else { return }
        if activeFileProviderDomain != nil {
            self.isMounted = true
            self.activeBackend = "File Provider"
            self.lastMountMessage = "Mounted in Finder Locations (\(activeMountURL.path))"
            return
        }

        let mountPath = mountedNFSPath ?? OpenDrivePaths.mountRootURL.path
        let mounted = Self.isMountPathActive(mountPath)
        self.isMounted = mounted
        if mounted {
            let activeURL = URL(fileURLWithPath: mountPath, isDirectory: true)
            let driveName = SharedSettings.shared.mountedDriveName
            self.activeMountURL = activeURL
            if nfsServer != nil {
                self.activeBackend = "Virtual Disk (NFSv3)"
                self.lastMountMessage = "Mounted as \"\(driveName)\" at \(mountPath)"
            } else {
                let suffix = activeBackend.isEmpty ? "" : " (\(activeBackend))"
                self.lastMountMessage = "Mounted at \(mountPath)\(suffix)"
            }
        } else {
            self.mountedNFSPath = nil
            self.activeBackend = ""
            self.activeMountURL = OpenDrivePaths.mountRootURL
            let staleWebDAV = self.webDAVServer
            let staleNFS = self.nfsServer
            let staleMDNS = self.mdnsRegistrar
            let dv = self.driveVolume
            self.webDAVServer = nil
            self.nfsServer = nil
            self.mdnsRegistrar = nil
            self.driveVolume = nil
            self.chunkCache = nil
            if staleWebDAV != nil || staleNFS != nil || dv != nil {
                Task {
                    await staleWebDAV?.stop()
                    await staleNFS?.stop()
                    staleMDNS?.stop()
                    await dv?.stopBackgroundSyncLoop()
                }
            }
            if !isMountInProgress {
                self.lastMountMessage = "Not mounted"
            }
        }
    }

    public func mountFilesystem() {
        guard !skipSystemChecks, !isMountInProgress else { return }
        if isMounted && (activeFileProviderDomain != nil || nfsServer != nil || webDAVServer != nil || activeBackend == "Apple FSKit") {
            return
        }

        isMountInProgress = true
        lastMountMessage = "Mounting Open Drive…"

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isMountInProgress = false }
            await self.performMount()
        }
    }

    public func switchBackendAndRemount() async {
        guard !skipSystemChecks, !isMountInProgress else { return }
        isMountInProgress = true
        lastMountMessage = "Switching mount mode…"
        defer { isMountInProgress = false }

        await performTeardown(forceUnmount: true)
        await performMount()
    }

    public func remountForRenamedDrive() async {
        guard !skipSystemChecks else { return }
        if isMounted {
            await switchBackendAndRemount()
        } else {
            FinderSidebarManager.removeOpenDriveItemsFromSidebar()
            activeMountURL = OpenDrivePaths.mountRootURL
            if !isMountInProgress {
                lastMountMessage = "Not mounted"
            }
        }
    }

    public func unmountFilesystem(force: Bool = false) {
        guard !skipSystemChecks else { return }
        lastMountMessage = "Unmounting Open Drive…"

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performTeardown(forceUnmount: force)
            self.refreshMountState()
        }
    }

    public func unmountSynchronouslyForTermination() {
        guard !skipSystemChecks else { return }

        if let domain = self.activeFileProviderDomain {
            self.activeFileProviderDomain = nil
            let fpSem = DispatchSemaphore(value: 0)
            NSFileProviderManager.remove(domain) { _ in
                fpSem.signal()
            }
            _ = fpSem.wait(timeout: .now() + 2.0)
        }

        // Clean Finder Sidebar entries while paths are still resolvable, then unmount BEFORE stopping servers.
        FinderSidebarManager.removeOpenDriveItemsFromSidebar()

        for mountPath in allCandidateMountPaths() where Self.isMountPathActive(mountPath) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/sbin/umount")
            proc.arguments = [mountPath]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try? proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 && Self.isMountPathActive(mountPath) {
                let forceProc = Process()
                forceProc.executableURL = URL(fileURLWithPath: "/sbin/umount")
                forceProc.arguments = ["-f", mountPath]
                forceProc.standardOutput = Pipe()
                forceProc.standardError = Pipe()
                try? forceProc.run()
                forceProc.waitUntilExit()
            }
        }
        Self.cleanupEmptyMountDirectories()

        let dav = self.webDAVServer
        let nfs = self.nfsServer
        let mdns = self.mdnsRegistrar
        let dv = self.driveVolume
        self.mountedNFSPath = nil
        self.webDAVServer = nil
        self.nfsServer = nil
        self.mdnsRegistrar = nil
        self.driveVolume = nil
        self.chunkCache = nil
        self.isMounted = false
        self.activeBackend = ""
        self.activeMountURL = OpenDrivePaths.mountRootURL

        if dav != nil || nfs != nil || dv != nil || mdns != nil {
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                await dav?.stop()
                await nfs?.stop()
                mdns?.stop()
                await dv?.stopBackgroundSyncLoop()
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 2.0)
        }
    }

    private func performTeardown(forceUnmount: Bool) async {
        if let oldDomain = self.activeFileProviderDomain {
            self.activeFileProviderDomain = nil
            try? await NSFileProviderManager.remove(oldDomain)
        }
        if let existingDomains = try? await NSFileProviderManager.domains() {
            for existing in existingDomains {
                try? await NSFileProviderManager.remove(existing)
            }
        }

        // Remove Finder Sidebar items first while URLs resolve cleanly, then unmount all Open Drive mounts.
        FinderSidebarManager.removeOpenDriveItemsFromSidebar()

        for mountPath in allCandidateMountPaths() where Self.isMountPathActive(mountPath) {
            let args = forceUnmount ? ["-f", mountPath] : [mountPath]
            var result = await Self.runCommand("/sbin/umount", arguments: args)
            if result.status != 0 && !forceUnmount && Self.isMountPathActive(mountPath) {
                result = await Self.runCommand("/sbin/umount", arguments: ["-f", mountPath])
            }
            if self.isMounted && !result.output.isEmpty && Self.isMountPathActive(mountPath) {
                self.lastMountMessage = "Unmount exited (\(result.status)): \(result.output)"
            }
        }
        Self.cleanupEmptyMountDirectories()

        let oldWebDAV = self.webDAVServer
        let oldNFS = self.nfsServer
        let oldMDNS = self.mdnsRegistrar
        let oldVolume = self.driveVolume
        self.mountedNFSPath = nil
        self.webDAVServer = nil
        self.nfsServer = nil
        self.mdnsRegistrar = nil
        self.driveVolume = nil
        self.chunkCache = nil
        self.isMounted = false
        self.activeBackend = ""
        self.activeMountURL = OpenDrivePaths.mountRootURL

        await oldWebDAV?.stop()
        await oldNFS?.stop()
        oldMDNS?.stop()
        await oldVolume?.stopBackgroundSyncLoop()
    }

    private func performMount() async {
        let driveName = SharedSettings.shared.mountedDriveName
        let mountURL = OpenDrivePaths.mountURL(forDriveName: driveName)

        // 1. Prefer registered FSKit extension if installed & permitted by macOS.
        if await Self.isFSKitExtensionRegistered() {
            try? FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
            let fsResult = await Self.runCommand(
                "/sbin/mount",
                arguments: ["-F", "-t", OpenDrivePaths.fsShortName, "opendrive://mount", mountURL.path]
            )
            if fsResult.status == 0 {
                self.mountedNFSPath = mountURL.path
                self.isMounted = true
                self.activeBackend = "Apple FSKit"
                self.activeMountURL = mountURL
                self.lastMountMessage = "Mounted at \(mountURL.path) (Apple FSKit)"
                return
            }
        }

        // Clean up any orphaned previous mount or registered domains before starting fresh.
        await performTeardown(forceUnmount: true)

        var startedVolume: DriveVolume?
        var startedWebDAV: LocalWebDAVServer?
        var startedNFS: LocalNFSServer?
        let startedMDNS: LocalMDNSRegistrar? = nil

        do {
            let dv = try DriveVolume(rootName: driveName)
            startedVolume = dv
            let cache = try ChunkCache(maxBytes: SharedSettings.shared.maxCacheBytes)
            await DriveVolumeBootstrapper.loadRegisteredAccounts(into: dv, cache: cache)
            await dv.refreshStorageQuotas()
            await dv.startBackgroundSyncLoop(intervalSeconds: 30.0)
            DriveVolumeBootstrapper.attachLiveObservers(driveVolume: dv, cache: cache) { [weak self] in
                Task { @MainActor in
                    self?.signalFileProviderRefresh()
                }
            }

            switch SharedSettings.shared.mountBackendMode {
            case .virtualDiskNFS:
                let exportPath = "/\(driveName)"
                let server = LocalNFSServer(driveVolume: dv, exportPath: exportPath)
                let nfsPort = try await server.start()
                startedNFS = server

                let preferredHost = LocalMDNSRegistrar.loopbackHostname(forDriveName: driveName)
                let resolvedHost = LocalMDNSRegistrar.resolveLoopbackHostname(preferred: preferredHost)

                try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
                let baseOptions = [
                    "vers=3",
                    "tcp",
                    "inet",
                    "port=\(nfsPort)",
                    "mountport=\(nfsPort)",
                    "noresvport",
                    "nolocks",
                    "locallocks",
                    "soft",
                    "intr",
                    "rsize=131072",
                    "wsize=131072",
                    "acregmin=3",
                    "acregmax=10",
                    "acdirmin=3",
                    "acdirmax=10"
                ]

                let remoteSpec = "\(resolvedHost):\(exportPath)"
                let nobrowseOptions = (baseOptions + ["nobrowse"]).joined(separator: ",")
                let result = await Self.runCommand(
                    "/sbin/mount_nfs",
                    arguments: ["-o", nobrowseOptions, remoteSpec, mountURL.path]
                )
                guard result.status == 0 else {
                    let detail = result.output.isEmpty ? "exit \(result.status)" : result.output
                    throw NSError(
                        domain: "OpenDriveMount",
                        code: Int(result.status),
                        userInfo: [NSLocalizedDescriptionKey: "mount_nfs failed (\(detail))"]
                    )
                }

                // Pin directly in Finder Sidebar Favourites for 1-click access; if pinning fails,
                // remount without `nobrowse` so Finder still exposes the volume normally.
                let pinned = FinderSidebarManager.pinInSidebar(url: mountURL, displayName: driveName)
                if !pinned {
                    _ = await Self.runCommand("/sbin/umount", arguments: ["-f", mountURL.path])
                    let browsableOptions = baseOptions.joined(separator: ",")
                    let fallbackResult = await Self.runCommand(
                        "/sbin/mount_nfs",
                        arguments: ["-o", browsableOptions, remoteSpec, mountURL.path]
                    )
                    guard fallbackResult.status == 0 else {
                        let detail = fallbackResult.output.isEmpty ? "exit \(fallbackResult.status)" : fallbackResult.output
                        throw NSError(
                            domain: "OpenDriveMount",
                            code: Int(fallbackResult.status),
                            userInfo: [NSLocalizedDescriptionKey: "mount_nfs fallback failed (\(detail))"]
                        )
                    }
                }

                self.driveVolume = dv
                self.chunkCache = cache
                self.nfsServer = server
                self.mdnsRegistrar = nil
                self.mountedNFSPath = mountURL.path
                self.activeMountURL = mountURL
                self.isMounted = true
                self.activeBackend = "Virtual Disk (NFSv3)"
                self.lastMountMessage = pinned
                    ? "Mounted as \"\(driveName)\" in Finder Sidebar"
                    : "Mounted at \(mountURL.path) (Virtual Disk • Cloud Space)"

            case .fileProvider:
                let server = LocalWebDAVServer(driveVolume: dv, bridgeOnly: true)
                _ = try await server.start()
                startedWebDAV = server
                let bridgePort = Int(await server.port)

                let bridgeUserInfo: [AnyHashable: Any] = [
                    "port": NSNumber(value: bridgePort),
                    "token": server.bridgeAuthToken
                ]
                let fpDisplayName = (driveName == OpenDrivePaths.defaultDriveName) ? "" : driveName
                let primaryDomain = NSFileProviderDomain(
                    identifier: NSFileProviderDomainIdentifier("OpenDrive"),
                    displayName: fpDisplayName
                )
                primaryDomain.supportsSyncingTrash = false
                primaryDomain.userInfo = bridgeUserInfo

                let activeDomain: NSFileProviderDomain
                do {
                    try await NSFileProviderManager.add(primaryDomain)
                    activeDomain = primaryDomain
                } catch {
                    let fallbackDomain = NSFileProviderDomain(
                        identifier: NSFileProviderDomainIdentifier("OpenDrive"),
                        displayName: driveName
                    )
                    fallbackDomain.supportsSyncingTrash = false
                    fallbackDomain.userInfo = bridgeUserInfo
                    try await NSFileProviderManager.add(fallbackDomain)
                    activeDomain = fallbackDomain
                }
                guard let fpManager = NSFileProviderManager(for: activeDomain) else {
                    throw NSError(
                        domain: "OpenDriveMount",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not resolve NSFileProviderManager for Open Drive domain."]
                    )
                }
                let visibleURL = try await fpManager.getUserVisibleURL(for: .rootContainer)

                self.driveVolume = dv
                self.chunkCache = cache
                self.webDAVServer = server
                self.activeFileProviderDomain = activeDomain
                self.mountedNFSPath = nil
                self.activeMountURL = visibleURL
                self.isMounted = true
                self.activeBackend = "File Provider"
                self.lastMountMessage = "Mounted in Finder Locations (\(visibleURL.path))"
                self.signalFileProviderRefresh()
            }
        } catch {
            self.activeFileProviderDomain = nil
            self.webDAVServer = nil
            self.nfsServer = nil
            self.mdnsRegistrar = nil
            self.mountedNFSPath = nil
            self.driveVolume = nil
            self.chunkCache = nil
            self.isMounted = false
            self.activeBackend = ""
            self.activeMountURL = OpenDrivePaths.mountRootURL
            FinderSidebarManager.removeOpenDriveItemsFromSidebar()
            if Self.isMountPathActive(mountURL.path) {
                _ = await Self.runCommand("/sbin/umount", arguments: ["-f", mountURL.path])
            }
            Self.cleanupEmptyMountDirectories()
            await startedWebDAV?.stop()
            await startedNFS?.stop()
            startedMDNS?.stop()
            await startedVolume?.stopBackgroundSyncLoop()
            self.lastMountMessage = "Mount failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Private Helpers

    private func allCandidateMountPaths() -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        let candidates = [
            mountedNFSPath,
            activeMountURL.path,
            OpenDrivePaths.mountRootURL.path,
            OpenDrivePaths.legacyMountRootURL.path
        ].compactMap { $0 } + Self.activeManagedMountPaths()

        for path in candidates where seen.insert(path).inserted {
            ordered.append(path)
        }
        return ordered
    }

    private nonisolated static func activeManagedMountPaths() -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let containerPrefix = OpenDrivePaths.mountsContainerURL.standardizedFileURL.path + "/"
            let legacyPath = OpenDrivePaths.legacyMountRootURL.standardizedFileURL.path
            var matches: [String] = []
            for line in output.components(separatedBy: "\n") {
                guard let onRange = line.range(of: " on "),
                      let parenRange = line.range(of: " (", range: onRange.upperBound..<line.endIndex) else {
                    continue
                }
                let mountPoint = String(line[onRange.upperBound..<parenRange.lowerBound])
                if mountPoint == legacyPath || mountPoint.hasPrefix(containerPrefix) {
                    matches.append(mountPoint)
                }
            }
            return matches
        } catch {
            return []
        }
    }

    private nonisolated static func cleanupEmptyMountDirectories() {
        let fm = FileManager.default
        let containerURL = OpenDrivePaths.mountsContainerURL
        if let children = try? fm.contentsOfDirectory(at: containerURL, includingPropertiesForKeys: nil) {
            for child in children where !isMountPathActive(child.path) {
                if let inner = try? fm.contentsOfDirectory(atPath: child.path), inner.isEmpty {
                    try? fm.removeItem(at: child)
                }
            }
        }
        let legacyURL = OpenDrivePaths.legacyMountRootURL
        if !isMountPathActive(legacyURL.path),
           let inner = try? fm.contentsOfDirectory(atPath: legacyURL.path),
           inner.isEmpty {
            try? fm.removeItem(at: legacyURL)
        }
    }

    private nonisolated static func isMountPathActive(_ mountPath: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let marker = " on \(mountPath) "
            return output.components(separatedBy: "\n").contains { $0.contains(marker) }
        } catch {
            return false
        }
    }

    private nonisolated static func isFSKitExtensionRegistered() async -> Bool {
        let fsBundleId = "org.opendrive.mac.fs"
        let result = await runCommand(
            "/usr/bin/pluginkit",
            arguments: ["-m", "-i", fsBundleId]
        )
        return result.status == 0 && result.output.contains(fsBundleId)
    }

    private nonisolated static func runCommand(
        _ path: String,
        arguments: [String]
    ) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments = arguments
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let text = (String(data: data, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: (proc.terminationStatus, text))
                } catch {
                    continuation.resume(returning: (-1, error.localizedDescription))
                }
            }
        }
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
            let stdPath = volumePathURL.standardizedFileURL.path
            let legacyPath = OpenDrivePaths.legacyMountRootURL.standardizedFileURL.path
            let containerPrefix = OpenDrivePaths.mountsContainerURL.standardizedFileURL.path + "/"
            guard stdPath == legacyPath || stdPath.hasPrefix(containerPrefix) else {
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
