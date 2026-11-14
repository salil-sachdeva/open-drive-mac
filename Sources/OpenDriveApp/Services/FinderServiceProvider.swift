import AppKit
import Foundation

/// macOS Finder Service (`NSServices`) receiver for "Send to Open Drive" (`⌘⇧C`).
@MainActor
public final class FinderServiceProvider: NSObject {
    private weak var viewModel: OpenDriveAppViewModel?

    public init(viewModel: OpenDriveAppViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    @objc public func uploadToOpenDrive(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else {
            return
        }
        Task { @MainActor in
            await viewModel?.enqueueDroppedFiles(urls: urls, targetFolderId: nil)
        }
    }
}
