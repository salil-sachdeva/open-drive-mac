import Foundation

// MARK: - Stale Name

/// A name that is temporarily reserved in a directory, persisted in the `staleNames` table.
public struct StaleNameRecord: Codable, Sendable, Equatable {
    public var dir: String
    public var name: String
    public var itemId: String
    public var foundAt: Double
    public var releasingAt: Double

    public init(dir: String, name: String, itemId: String, foundAt: Double, releasingAt: Double) {
        self.dir = dir
        self.name = name
        self.itemId = itemId
        self.foundAt = foundAt
        self.releasingAt = releasingAt
    }
}

// MARK: - Recent Folder

/// A recently used destination folder, persisted in the `recentFolders` table.
public struct RecentFolderRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var usedAt: Double

    public init(id: String, name: String, usedAt: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.name = name
        self.usedAt = usedAt
    }
}
