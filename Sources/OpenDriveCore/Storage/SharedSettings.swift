import Foundation

/// Selectable Finder mounting backend for Open Drive.
public enum MountBackendMode: String, Codable, CaseIterable, Sendable {
    case virtualDiskNFS = "nfs"
    case fileProvider = "fileProvider"

    public var displayTitle: String {
        switch self {
        case .virtualDiskNFS:
            return "Virtual Disk (Accurate Cloud Space)"
        case .fileProvider:
            return "CloudStorage (Apple File Provider)"
        }
    }
}

/// App Group–backed preferences shared between `OpenDriveApp` and `OpenDriveFS`.
public final class SharedSettings: @unchecked Sendable {
    public enum Keys {
        public static let googleClientId = "googleClientId"
        public static let googleClientSecret = "googleClientSecret"
        public static let maxCacheGiB = "maxCacheGiB"
        public static let bandwidthLimitMbps = "bandwidthLimitMbps"
        public static let pauseOnMetered = "pauseOnMetered"
        public static let searchHotkeyEnabled = "searchHotkeyEnabled"
        public static let hideDockIconWhenClosed = "hideDockIconWhenClosed"
        public static let mountBackendMode = "mountBackendMode"
        public static let mountedDriveName = "mountedDriveName"
    }

    public static let shared = SharedSettings()

    private let defaults: UserDefaults
    private let legacyFallbackEnabled: Bool
    private let lock = NSLock()
    public let bundledGoogleClientId: String
    public let bundledGoogleClientSecret: String

    public init(
        suiteName: String? = OpenDrivePaths.appGroupIdentifier,
        bundledClientId: String? = nil,
        bundledClientSecret: String? = nil
    ) {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            self.defaults = suite
            self.legacyFallbackEnabled = (suiteName == OpenDrivePaths.appGroupIdentifier)
        } else {
            self.defaults = .standard
            self.legacyFallbackEnabled = false
        }
        let infoClientId = (Bundle.main.object(forInfoDictionaryKey: "OpenDriveGoogleClientID") as? String ?? "")
        let infoClientSecret = (Bundle.main.object(forInfoDictionaryKey: "OpenDriveGoogleClientSecret") as? String ?? "")
        self.bundledGoogleClientId = (bundledClientId ?? infoClientId).trimmingCharacters(in: .whitespacesAndNewlines)
        self.bundledGoogleClientSecret = (bundledClientSecret ?? infoClientSecret).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var hasBundledGoogleOAuthCredentials: Bool {
        !bundledGoogleClientId.isEmpty
    }

    public var googleClientId: String {
        get {
            lock.withLock {
                if let value = defaults.string(forKey: Keys.googleClientId),
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
                if legacyFallbackEnabled,
                   let legacy = UserDefaults.standard.string(forKey: Keys.googleClientId),
                   !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    defaults.set(legacy, forKey: Keys.googleClientId)
                    return legacy
                }
                return bundledGoogleClientId
            }
        }
        set {
            lock.withLock {
                defaults.set(newValue, forKey: Keys.googleClientId)
            }
        }
    }

    public var googleClientSecret: String {
        get {
            lock.withLock {
                if let value = defaults.string(forKey: Keys.googleClientSecret),
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
                if legacyFallbackEnabled,
                   let legacy = UserDefaults.standard.string(forKey: Keys.googleClientSecret),
                   !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    defaults.set(legacy, forKey: Keys.googleClientSecret)
                    return legacy
                }
                return bundledGoogleClientSecret
            }
        }
        set {
            lock.withLock {
                defaults.set(newValue, forKey: Keys.googleClientSecret)
            }
        }
    }

    public var maxCacheGiB: Double {
        get {
            lock.withLock {
                guard defaults.object(forKey: Keys.maxCacheGiB) != nil else { return 5.0 }
                return Self.clampCacheGiB(defaults.double(forKey: Keys.maxCacheGiB))
            }
        }
        set {
            lock.withLock {
                defaults.set(Self.clampCacheGiB(newValue), forKey: Keys.maxCacheGiB)
            }
        }
    }

    public var maxCacheBytes: Int64 {
        Int64(maxCacheGiB * 1024 * 1024 * 1024)
    }

    public var bandwidthLimitMbps: Double {
        get {
            lock.withLock {
                guard defaults.object(forKey: Keys.bandwidthLimitMbps) != nil else { return 0.0 }
                return Self.clampBandwidthMbps(defaults.double(forKey: Keys.bandwidthLimitMbps))
            }
        }
        set {
            lock.withLock {
                defaults.set(Self.clampBandwidthMbps(newValue), forKey: Keys.bandwidthLimitMbps)
            }
        }
    }

    public var bandwidthMode: BandwidthMode {
        let mbps = bandwidthLimitMbps
        return mbps > 0 ? .fixed(mbps: mbps) : .off
    }

    public var pauseOnMetered: Bool {
        get {
            lock.withLock {
                guard defaults.object(forKey: Keys.pauseOnMetered) != nil else { return true }
                return defaults.bool(forKey: Keys.pauseOnMetered)
            }
        }
        set {
            lock.withLock {
                defaults.set(newValue, forKey: Keys.pauseOnMetered)
            }
        }
    }

    public var searchHotkeyEnabled: Bool {
        get {
            lock.withLock {
                guard defaults.object(forKey: Keys.searchHotkeyEnabled) != nil else { return true }
                return defaults.bool(forKey: Keys.searchHotkeyEnabled)
            }
        }
        set {
            lock.withLock {
                defaults.set(newValue, forKey: Keys.searchHotkeyEnabled)
            }
        }
    }

    public var hideDockIconWhenClosed: Bool {
        get {
            lock.withLock {
                guard defaults.object(forKey: Keys.hideDockIconWhenClosed) != nil else { return true }
                return defaults.bool(forKey: Keys.hideDockIconWhenClosed)
            }
        }
        set {
            lock.withLock {
                defaults.set(newValue, forKey: Keys.hideDockIconWhenClosed)
            }
        }
    }

    public var mountBackendMode: MountBackendMode {
        get {
            lock.withLock {
                guard let raw = defaults.string(forKey: Keys.mountBackendMode),
                      let mode = MountBackendMode(rawValue: raw) else {
                    return .virtualDiskNFS
                }
                return mode
            }
        }
        set {
            lock.withLock {
                defaults.set(newValue.rawValue, forKey: Keys.mountBackendMode)
            }
        }
    }

    public var mountedDriveName: String {
        get {
            lock.withLock {
                OpenDrivePaths.sanitizeDriveName(defaults.string(forKey: Keys.mountedDriveName) ?? OpenDrivePaths.defaultDriveName)
            }
        }
        set {
            lock.withLock {
                defaults.set(OpenDrivePaths.sanitizeDriveName(newValue), forKey: Keys.mountedDriveName)
            }
        }
    }

    private static func clampCacheGiB(_ value: Double) -> Double {
        min(50.0, max(1.0, value))
    }

    private static func clampBandwidthMbps(_ value: Double) -> Double {
        min(1000.0, max(0.0, value))
    }
}
