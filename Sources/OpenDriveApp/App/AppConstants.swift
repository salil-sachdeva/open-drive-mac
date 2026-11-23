import Foundation

/// Shared literals used across the app target.
enum AppConstants {
    static let appName = "Open Drive"
    static let defaultAccountName = "Google Drive"
    static let defaultRootId = "root"
}

extension Int64 {
    /// Human-readable file size, e.g. "12.3 MB".
    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
