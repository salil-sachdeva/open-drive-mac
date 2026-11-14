import Darwin
import Foundation

/// Ephemeral loopback HTTP listener (`127.0.0.1:<port>/oauth2callback`) for desktop OAuth 2.0 PKCE redirects.
public final class GoogleOAuthLoopbackServer: @unchecked Sendable {
    public let port: UInt16
    public let redirectURI: String
    private let listenFD: Int32

    public init(preferredPort: UInt16 = 0) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw GoogleDriveError.oauthFailed("Failed to create loopback socket")
        }

        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = preferredPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = String(cString: strerror(errno))
            Darwin.close(fd)
            throw GoogleDriveError.oauthFailed("Loopback bind failed: \(err)")
        }

        guard Darwin.listen(fd, 4) == 0 else {
            let err = String(cString: strerror(errno))
            Darwin.close(fd)
            throw GoogleDriveError.oauthFailed("Loopback listen failed: \(err)")
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.getsockname(fd, sockPtr, &addrLen)
            }
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)
        self.redirectURI = "http://127.0.0.1:\(self.port)/oauth2callback"
    }

    deinit {
        if listenFD >= 0 {
            Darwin.close(listenFD)
        }
    }

    public func waitForAuthorizationCode(expectedState: String, timeoutSeconds: TimeInterval = 180) async throws -> String {
        let fd = self.listenFD
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let pollMs = Int32(max(1, Int(timeoutSeconds * 1000)))
                let ready = Darwin.poll(&pfd, 1, pollMs)
                guard ready > 0 else {
                    continuation.resume(throwing: GoogleDriveError.oauthFailed("Timed out waiting for browser OAuth callback"))
                    return
                }

                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        Darwin.accept(fd, sockPtr, &clientLen)
                    }
                }
                guard clientFD >= 0 else {
                    continuation.resume(throwing: GoogleDriveError.oauthFailed("Failed to accept loopback connection"))
                    return
                }
                defer { Darwin.close(clientFD) }

                do {
                    let code = try Self.processClientFD(clientFD, expectedState: expectedState)
                    continuation.resume(returning: code)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public static func processClientFD(_ clientFD: Int32, expectedState: String) throws -> String {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = Darwin.read(clientFD, &buffer, buffer.count - 1)
        guard bytesRead > 0 else {
            throw GoogleDriveError.oauthFailed("Empty request on loopback callback")
        }
        let rawRequest = String(decoding: buffer.prefix(bytesRead), as: UTF8.self)
        let firstLine = rawRequest.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        let requestTarget = parts.count >= 2 ? String(parts[1]) : "/"

        do {
            let code = try GoogleOAuth.parseAuthorizationCallback(
                requestPathOrURL: requestTarget,
                expectedState: expectedState
            )
            let html = """
            <!DOCTYPE html><html><head><meta charset="utf-8"><title>Open Drive Connected</title>
            <style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#111;color:#f5f5f7}
            .card{background:#1c1c1e;padding:32px 40px;border-radius:16px;text-align:center;box-shadow:0 12px 32px rgba(0,0,0,0.4)}
            h2{margin:0 0 8px;color:#30d158}p{margin:0;color:#98989d}</style></head>
            <body><div class="card"><h2>✓ Google Drive Connected</h2><p>You can close this browser tab and return to Open Drive.</p></div></body></html>
            """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            _ = response.withCString { ptr in
                Darwin.write(clientFD, ptr, strlen(ptr))
            }
            return code
        } catch {
            let html = "<!DOCTYPE html><html><body><h3>Authentication Error</h3><p>\(error.localizedDescription)</p></body></html>"
            let response = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            _ = response.withCString { ptr in
                Darwin.write(clientFD, ptr, strlen(ptr))
            }
            throw error
        }
    }
}
