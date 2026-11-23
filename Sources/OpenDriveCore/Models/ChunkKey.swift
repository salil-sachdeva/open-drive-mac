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
        let safeDriveId = Self.sanitizeSegment(driveId)
        let safeVersion = Self.sanitizeSegment(contentVersion)
        let safeIndex = max(0, index)
        return "\(safeDriveId)_\(safeVersion)_\(safeIndex).chunk"
    }

    public static func sanitizeSegment(_ raw: String) -> String {
        let mapped = String(raw.map { ch -> Character in
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-") {
                return ch
            }
            return "_"
        })
        var cleaned = mapped
        while cleaned.contains("..") {
            cleaned = cleaned.replacingOccurrences(of: "..", with: "__")
        }
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        return cleaned.isEmpty ? "x" : String(cleaned.prefix(128))
    }

    public var description: String {
        "\(driveId)@\(contentVersion)#\(index)"
    }
}
