// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "open-drive-mac",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "OpenDriveCore",
            targets: ["OpenDriveCore"]
        ),
        .executable(
            name: "OpenDriveApp",
            targets: ["OpenDriveApp"]
        ),
        .executable(
            name: "OpenDriveFS",
            targets: ["OpenDriveFS"]
        ),
        .executable(
            name: "open-drive-mcp",
            targets: ["OpenDriveMCP"]
        )
    ],
    targets: [
        .target(
            name: "OpenDriveCore",
            path: "Sources/OpenDriveCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("Network"),
                .linkedFramework("AuthenticationServices")
            ]
        ),
        .executableTarget(
            name: "OpenDriveFS",
            dependencies: ["OpenDriveCore"],
            path: "Sources/OpenDriveFS",
            linkerSettings: [
                .linkedFramework("FSKit"),
                .linkedFramework("ExtensionFoundation")
            ]
        ),
        .executableTarget(
            name: "OpenDriveMCP",
            dependencies: ["OpenDriveCore"],
            path: "Sources/OpenDriveMCP"
        ),
        .executableTarget(
            name: "OpenDriveApp",
            dependencies: ["OpenDriveCore"],
            path: "Sources/OpenDriveApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "OpenDriveCoreTests",
            dependencies: ["OpenDriveCore"],
            path: "Tests/OpenDriveCoreTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
