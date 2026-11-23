import Foundation

// MARK: - Case-Insensitive Collision Disambiguation (`shownAs` / `folded`)

extension MetadataStore {
    public static func sanitizeDisplayName(_ name: String) -> String {
        let controlStripped = String(name.unicodeScalars.filter { scalar in
            !(scalar.value < 0x20 || scalar.value == 0x7F)
        })
        let replaced = controlStripped.replacingOccurrences(of: "/", with: "-")
        let trimmed = replaced.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Untitled" }
        if trimmed == "." { return "_" }
        if trimmed == ".." { return "__" }
        return replaced
    }

    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }

    public static func disambiguate(item: DriveItem, againstSiblings siblings: [DriveItem]) -> DriveItem {
        let sanitizedBase = sanitizeDisplayName(item.name)
        let existingFolded = Set(siblings.map(\.folded))
        var candidateName = sanitizedBase
        var candidateFolded = fold(candidateName)

        if !existingFolded.contains(candidateFolded) {
            var copy = item
            copy.shownAs = candidateName
            copy.folded = candidateFolded
            return copy
        }

        let nsName = sanitizedBase as NSString
        let ext = nsName.pathExtension
        let stem = nsName.deletingPathExtension
        let shortId = String(item.driveId.prefix(6))

        var counter = 2
        while existingFolded.contains(candidateFolded) {
            if counter == 2 {
                candidateName = ext.isEmpty ? "\(stem) (\(shortId))" : "\(stem) (\(shortId)).\(ext)"
            } else {
                candidateName = ext.isEmpty ? "\(stem) (\(shortId)-\(counter))" : "\(stem) (\(shortId)-\(counter)).\(ext)"
            }
            candidateFolded = fold(candidateName)
            counter += 1
        }

        var copy = item
        copy.shownAs = candidateName
        copy.folded = candidateFolded
        return copy
    }
}
