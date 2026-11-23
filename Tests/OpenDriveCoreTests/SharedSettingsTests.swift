import XCTest
@testable import OpenDriveCore

final class SharedSettingsTests: XCTestCase {
    func testDefaultsClampingAndPersistenceInIsolatedSuite() {
        let suiteName = "org.opendrive.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let settings = SharedSettings(suiteName: suiteName)

        // Verify defaults
        XCTAssertEqual(settings.googleClientId, "")
        XCTAssertEqual(settings.googleClientSecret, "")
        XCTAssertEqual(settings.maxCacheGiB, 5.0)
        XCTAssertEqual(settings.maxCacheBytes, Int64(5.0 * 1024 * 1024 * 1024))
        XCTAssertEqual(settings.bandwidthLimitMbps, 0.0)
        XCTAssertEqual(settings.bandwidthMode, .off)
        XCTAssertTrue(settings.pauseOnMetered)
        XCTAssertTrue(settings.searchHotkeyEnabled)
        XCTAssertTrue(settings.hideDockIconWhenClosed)
        XCTAssertEqual(settings.mountBackendMode, .virtualDiskNFS)

        // Verify clamping and persistence
        settings.googleClientId = "client-id-123"
        settings.googleClientSecret = "secret-xyz"
        settings.maxCacheGiB = 100.0
        settings.bandwidthLimitMbps = 2500.0
        settings.pauseOnMetered = false
        settings.searchHotkeyEnabled = false
        settings.hideDockIconWhenClosed = false
        settings.mountBackendMode = .fileProvider

        let reloaded = SharedSettings(suiteName: suiteName)
        XCTAssertEqual(reloaded.googleClientId, "client-id-123")
        XCTAssertEqual(reloaded.googleClientSecret, "secret-xyz")
        XCTAssertEqual(reloaded.maxCacheGiB, 50.0)
        XCTAssertEqual(reloaded.maxCacheBytes, Int64(50.0 * 1024 * 1024 * 1024))
        XCTAssertEqual(reloaded.bandwidthLimitMbps, 1000.0)
        XCTAssertEqual(reloaded.bandwidthMode, .fixed(mbps: 1000.0))
        XCTAssertFalse(reloaded.pauseOnMetered)
        XCTAssertFalse(reloaded.searchHotkeyEnabled)
        XCTAssertFalse(reloaded.hideDockIconWhenClosed)
        XCTAssertEqual(reloaded.mountBackendMode, .fileProvider)

        // Lower-bound clamping
        settings.maxCacheGiB = 0.2
        settings.bandwidthLimitMbps = -10.0
        XCTAssertEqual(reloaded.maxCacheGiB, 1.0)
        XCTAssertEqual(reloaded.bandwidthLimitMbps, 0.0)
        XCTAssertEqual(reloaded.bandwidthMode, .off)
    }

    func testBundledOAuthCredentialFallbackAndOverride() {
        let suiteName = "org.opendrive.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let settings = SharedSettings(
            suiteName: suiteName,
            bundledClientId: "bundled-client-id.apps.googleusercontent.com",
            bundledClientSecret: "bundled-secret"
        )
        XCTAssertTrue(settings.hasBundledGoogleOAuthCredentials)
        XCTAssertEqual(settings.googleClientId, "bundled-client-id.apps.googleusercontent.com")
        XCTAssertEqual(settings.googleClientSecret, "bundled-secret")

        // Empty strings in defaults still fall back cleanly to bundled credentials.
        settings.googleClientId = "   "
        settings.googleClientSecret = ""
        XCTAssertEqual(settings.googleClientId, "bundled-client-id.apps.googleusercontent.com")
        XCTAssertEqual(settings.googleClientSecret, "bundled-secret")

        // Non-empty override supersedes the bundled default.
        settings.googleClientId = "custom-client-id.apps.googleusercontent.com"
        settings.googleClientSecret = "custom-secret"
        XCTAssertEqual(settings.googleClientId, "custom-client-id.apps.googleusercontent.com")
        XCTAssertEqual(settings.googleClientSecret, "custom-secret")

        let noBundled = SharedSettings(suiteName: suiteName, bundledClientId: "", bundledClientSecret: "")
        XCTAssertFalse(noBundled.hasBundledGoogleOAuthCredentials)
    }

    func testMountedDriveNameSanitizationPersistenceAndLoopbackHost() {
        let suiteName = "org.opendrive.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let settings = SharedSettings(suiteName: suiteName)
        XCTAssertEqual(settings.mountedDriveName, OpenDrivePaths.defaultDriveName)

        settings.mountedDriveName = "  ..Google:/Drive\\Root  "
        XCTAssertEqual(settings.mountedDriveName, "Google--Drive-Root")
        XCTAssertEqual(
            OpenDrivePaths.mountURL(forDriveName: "My Drive").path,
            OpenDrivePaths.mountsContainerURL.appendingPathComponent("My Drive").path
        )

        settings.mountedDriveName = "   ...   "
        XCTAssertEqual(settings.mountedDriveName, "Open Drive")

        XCTAssertEqual(LocalMDNSRegistrar.loopbackHostname(forDriveName: "Open Drive"), "Open-Drive.localhost")
        XCTAssertEqual(LocalMDNSRegistrar.loopbackHostname(forDriveName: "My Google Drive!"), "My-Google-Drive.localhost")
        XCTAssertEqual(LocalMDNSRegistrar.loopbackHostname(forDriveName: "///"), "Open-Drive.localhost")
    }
}
