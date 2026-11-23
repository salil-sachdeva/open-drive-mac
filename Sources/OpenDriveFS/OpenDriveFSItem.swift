import Foundation
import FSKit
import OpenDriveCore

/// `FSItem` wrapper binding an FSKit inode to a `DriveVolume.VFSNode` and in-memory extended attributes.
@available(macOS 15.4, *)
public final class OpenDriveFSItem: FSItem, @unchecked Sendable {
    public let itemId: UInt64
    public var vfsNode: DriveVolume.VFSNode
    private let xattrLock = NSLock()
    private var xattrs: [String: Data] = [:]

    public init(node: DriveVolume.VFSNode) {
        self.itemId = node.itemId
        self.vfsNode = node
        super.init()
    }

    public func getXattr(named name: String) -> Data? {
        xattrLock.lock()
        defer { xattrLock.unlock() }
        return xattrs[name]
    }

    public func setXattr(named name: String, data: Data?) {
        xattrLock.lock()
        defer { xattrLock.unlock() }
        if let data {
            xattrs[name] = data
        } else {
            xattrs.removeValue(forKey: name)
        }
    }

    public func listXattrNames() -> [String] {
        xattrLock.lock()
        defer { xattrLock.unlock() }
        return Array(xattrs.keys)
    }
}
