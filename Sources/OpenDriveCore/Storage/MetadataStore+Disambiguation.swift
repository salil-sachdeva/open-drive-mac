import Foundation

// MARK: - Case-Insensitive Collision Disambiguation (`shownAs` / `folded`)

extension MetadataStore {
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }

    public static func disambiguate(item: DriveItem, againstSiblings siblings: [DriveItem]) -> DriveItem {
        let existingFolded = Set(siblings.map(\.folded))
        var candidateName = item.name
        var candidateFolded = fold(candidateName)

        if !existingFolded.contains(candidateFolded) {
            var copy = item
            copy.shownAs = candidateName
            copy.folded = candidateFolded
            return copy
        }

        let nsName = item.name as NSString
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
