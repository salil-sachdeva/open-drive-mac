import Foundation

/// Shared literals used across the app target.
enum AppConstants {
    static let appName = "Open Drive"
    static let defaultAccountName = "Google Drive"
    static let defaultRootId = "root"

    /// `UserDefaults` keys.
    enum DefaultsKey {
        static let googleClientId = "googleClientId"
        static let googleClientSecret = "googleClientSecret"
    }

    /// Path of the bundled `open-drive-mcp` helper binary.
    static var mcpBinaryPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/open-drive-mcp").path
    }
}

extension Int64 {
    /// Human-readable file size, e.g. "12.3 MB".
    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
