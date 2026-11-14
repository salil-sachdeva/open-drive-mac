/// Addresses a single cached chunk of a specific content version of a file.
public struct ChunkKey: Hashable, Sendable, CustomStringConvertible {
    public let driveId: String
    public let contentVersion: String
    public let index: Int

    public init(driveId: String, contentVersion: String, index: Int) {
        self.driveId = driveId
        self.contentVersion = contentVersion
        self.index = index
    }

    public var cacheFileName: String {
        let safeDriveId = driveId.replacingOccurrences(of: "/", with: "_")
        let safeVersion = contentVersion.replacingOccurrences(of: "/", with: "_")
        return "\(safeDriveId)_\(safeVersion)_\(index).chunk"
    }

    public var description: String {
        "\(driveId)@\(contentVersion)#\(index)"
    }
}
