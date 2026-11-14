import SwiftUI

/// Menu-bar entry point: hosts the status-item popover and the Settings window.
@main
struct OpenDriveApp: App {
    @StateObject private var viewModel = OpenDriveAppViewModel()

    var body: some Scene {
        MenuBarExtra(AppConstants.appName, systemImage: "externaldrive.badge.icloud") {
            MenuBarRootView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}
