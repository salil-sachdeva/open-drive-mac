import Foundation

/// A file or folder in the virtual filesystem, persisted in the `items` table.
public struct DriveItem: Codable, Sendable, Equatable {
    public var driveId: String
    public var parentId: String?
    public var name: String
    public var encName: String?
    public var isFolder: Bool
    public var size: Int64
    public var mime: String
    public var md5: String?
    public var version: String?
    public var modifiedTime: Double
    public var isEncrypted: Bool
    public var pinned: Bool
    public var lastOpenedAt: Double?
    public var trashedAt: Double?
    public var folded: String
    public var shownAs: String
    public var tampered: Bool
    public var appAuthorized: Bool
    public var posixMode: UInt32?
    public var symlinkTarget: String?

    public var isSymlink: Bool {
        symlinkTarget != nil
    }

    public init(
        driveId: String,
        parentId: String?,
        name: String,
        encName: String? = nil,
        isFolder: Bool,
        size: Int64 = 0,
        mime: String = "application/octet-stream",
        md5: String? = nil,
        version: String? = nil,
        modifiedTime: Double = Date().timeIntervalSince1970,
        isEncrypted: Bool = false,
        pinned: Bool = false,
        lastOpenedAt: Double? = nil,
        trashedAt: Double? = nil,
        folded: String? = nil,
        shownAs: String? = nil,
        tampered: Bool = false,
        appAuthorized: Bool = true,
        posixMode: UInt32? = nil,
        symlinkTarget: String? = nil
    ) {
        self.driveId = driveId
        self.parentId = parentId
        self.name = name
        self.encName = encName
        self.isFolder = isFolder
        self.size = size
        self.mime = mime
        self.md5 = md5
        self.version = version
        self.modifiedTime = modifiedTime
        self.isEncrypted = isEncrypted
        self.pinned = pinned
        self.lastOpenedAt = lastOpenedAt
        self.trashedAt = trashedAt
        self.folded = folded ?? name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        self.shownAs = shownAs ?? name
        self.tampered = tampered
        self.appAuthorized = appAuthorized
        self.posixMode = posixMode
        self.symlinkTarget = symlinkTarget
    }

    /// Non-folder Google Workspace virtual documents (Docs, Sheets, Slides, etc.)
    /// have no direct binary byte stream and are excluded from the POSIX filesystem.
    public var isGoogleWorkspaceVirtualDocument: Bool {
        !isFolder && mime.hasPrefix("application/vnd.google-apps.")
    }

    /// Stable content version token used as part of `ChunkKey`.
    public var contentVersionToken: String {
        if let version, !version.isEmpty {
            return version
        }
        if let md5, !md5.isEmpty {
            return md5
        }
        return "\(Int64(modifiedTime * 1000))-\(size)"
    }
}
