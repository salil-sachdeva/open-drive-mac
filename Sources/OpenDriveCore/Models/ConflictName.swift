import Foundation

/// Builds names for conflicted copies of files.
public enum ConflictName {
    /// Returns `"<stem> (conflict from yyyy-MM-dd HH.mm).<ext>"`.
    public static func make(for originalName: String, at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let timestamp = formatter.string(from: date)

        let nsName = originalName as NSString
        let ext = nsName.pathExtension
        let stem = nsName.deletingPathExtension
        if ext.isEmpty {
            return "\(originalName) (conflict from \(timestamp))"
        } else {
            return "\(stem) (conflict from \(timestamp)).\(ext)"
        }
    }
}
