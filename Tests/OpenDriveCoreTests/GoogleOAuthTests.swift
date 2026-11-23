import Darwin
import XCTest
@testable import OpenDriveCore

final class GoogleOAuthTests: XCTestCase {
    func testGoogleOAuthPKCEAndLoopbackCallbackServer() async throws {
        let pkce = GoogleOAuth.PKCEChallenge()
        XCTAssertFalse(pkce.verifier.isEmpty)
        XCTAssertFalse(pkce.challenge.isEmpty)
        XCTAssertNotEqual(pkce.verifier, pkce.challenge)

        let validCode = try GoogleOAuth.parseAuthorizationCallback(
            requestPathOrURL: "/oauth2callback?code=4/0AeanS-test-code&state=\(pkce.state)",
            expectedState: pkce.state
        )
        XCTAssertEqual(validCode, "4/0AeanS-test-code")

        XCTAssertThrowsError(
            try GoogleOAuth.parseAuthorizationCallback(
                requestPathOrURL: "/oauth2callback?code=4/0AeanS-test-code&state=wrong-state",
                expectedState: pkce.state
            )
        )

        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer {
            Darwin.close(fds[0])
            Darwin.close(fds[1])
        }

        let httpReq = "GET /oauth2callback?code=live-loopback-code-123&state=\(pkce.state) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        _ = httpReq.withCString { ptr in
            Darwin.write(fds[0], ptr, strlen(ptr))
        }
        let captured = try GoogleOAuthLoopbackServer.processClientFD(fds[1], expectedState: pkce.state)
        XCTAssertEqual(captured, "live-loopback-code-123")

        var respBuf = [UInt8](repeating: 0, count: 4096)
        let nRead = Darwin.read(fds[0], &respBuf, respBuf.count - 1)
        XCTAssertGreaterThan(nRead, 0)
        let httpRespText = String(decoding: respBuf.prefix(nRead), as: UTF8.self)
        XCTAssertTrue(httpRespText.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(httpRespText.contains("Google Drive Connected"))

        if let loopback = try? GoogleOAuthLoopbackServer() {
            XCTAssertGreaterThan(loopback.port, 0)
            XCTAssertEqual(loopback.redirectURI, "http://127.0.0.1:\(loopback.port)/oauth2callback")
        }
    }
}
