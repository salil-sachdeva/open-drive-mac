import Foundation

// MARK: - Upload State

/// Lifecycle state of a resumable upload.
public enum UploadState: String, Codable, Sendable {
    case queued
    case uploading
    case committing
    case paused
    case failed
    case done
}

/// Why an upload is currently paused.
public enum PauseReason: String, Codable, Sendable {
    case manual
    case metered
    case offline
    case auth
    case space
}

/// Upload bandwidth limiting policy.
public enum BandwidthMode: Codable, Sendable, Equatable {
    case off
    case auto
    case fixed(mbps: Double)
}

// MARK: - Upload Record

/// A resumable upload, persisted in the `uploads` table.
public struct UploadRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var localPath: String
    public var parentId: String
    public var targetDriveId: String?
    public var name: String
    public var size: Int64
    public var mime: String
    public var state: UploadState
    public var sessionURL: String?
    public var offset: Int64
    public var attempts: Int
    public var lastError: String?
    public var retryAt: Double?
    public var pausedReason: PauseReason?
    public var createdAt: Double
    public var baseVersion: String?
    public var encrypt: Bool
    public var resultDriveId: String?
    public var resultVersion: String?
    public var renamedLate: Bool
    public var baseHash: String?
    public var resultHash: String?
    public var cancelRequested: Bool

    public init(
        id: String = UUID().uuidString,
        localPath: String,
        parentId: String,
        targetDriveId: String? = nil,
        name: String,
        size: Int64,
        mime: String = "application/octet-stream",
        state: UploadState = .queued,
        sessionURL: String? = nil,
        offset: Int64 = 0,
        attempts: Int = 0,
        lastError: String? = nil,
        retryAt: Double? = nil,
        pausedReason: PauseReason? = nil,
        createdAt: Double = Date().timeIntervalSince1970,
        baseVersion: String? = nil,
        encrypt: Bool = false,
        resultDriveId: String? = nil,
        resultVersion: String? = nil,
        renamedLate: Bool = false,
        baseHash: String? = nil,
        resultHash: String? = nil,
        cancelRequested: Bool = false
    ) {
        self.id = id
        self.localPath = localPath
        self.parentId = parentId
        self.targetDriveId = targetDriveId
        self.name = name
        self.size = size
        self.mime = mime
        self.state = state
        self.sessionURL = sessionURL
        self.offset = offset
        self.attempts = attempts
        self.lastError = lastError
        self.retryAt = retryAt
        self.pausedReason = pausedReason
        self.createdAt = createdAt
        self.baseVersion = baseVersion
        self.encrypt = encrypt
        self.resultDriveId = resultDriveId
        self.resultVersion = resultVersion
        self.renamedLate = renamedLate
        self.baseHash = baseHash
        self.resultHash = resultHash
        self.cancelRequested = cancelRequested
    }
}
