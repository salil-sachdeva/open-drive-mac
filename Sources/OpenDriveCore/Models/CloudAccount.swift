/// A connected cloud account, persisted in the `account` table.
public struct CloudAccount: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var email: String?
    public var rootId: String?
    public var trashId: String?
    public var metaId: String?
    public var changesPageToken: String?
    public var encryptionEnabled: Bool
    public var rootCreatedAt: Double?
    public var wholeDrive: Bool
    public var mountRootId: String?

    public init(
        id: String,
        displayName: String,
        email: String? = nil,
        rootId: String? = nil,
        trashId: String? = nil,
        metaId: String? = nil,
        changesPageToken: String? = nil,
        encryptionEnabled: Bool = false,
        rootCreatedAt: Double? = nil,
        wholeDrive: Bool = false,
        mountRootId: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.rootId = rootId
        self.trashId = trashId
        self.metaId = metaId
        self.changesPageToken = changesPageToken
        self.encryptionEnabled = encryptionEnabled
        self.rootCreatedAt = rootCreatedAt
        self.wholeDrive = wholeDrive
        self.mountRootId = mountRootId
    }
}
