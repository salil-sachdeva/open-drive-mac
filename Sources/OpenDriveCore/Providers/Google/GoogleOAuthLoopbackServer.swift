import Darwin
import Foundation

/// Ephemeral loopback HTTP listener (`127.0.0.1:<port>/oauth2callback`) for desktop OAuth 2.0 PKCE redirects.
public final class GoogleOAuthLoopbackServer: @unchecked Sendable {
    public let port: UInt16
    public let redirectURI: String
    private let listenFD: Int32
    private let lock = NSLock()
    private var cancelled = false
    private var closed = false

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
        closeListenSocketIfNeeded()
    }

    public func cancel() {
        lock.withLock {
            cancelled = true
            if !closed && listenFD >= 0 {
                Darwin.close(listenFD)
                closed = true
            }
        }
    }

    private func isCancelled() -> Bool {
        lock.withLock { cancelled }
    }

    private func closeListenSocketIfNeeded() {
        lock.withLock {
            if !closed && listenFD >= 0 {
                Darwin.close(listenFD)
                closed = true
            }
        }
    }

    public func waitForAuthorizationCode(expectedState: String, timeoutSeconds: TimeInterval = 180) async throws -> String {
        let fd = self.listenFD
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let deadline = Date().addingTimeInterval(timeoutSeconds)

                while true {
                    if self.isCancelled() {
                        continuation.resume(throwing: GoogleDriveError.oauthFailed("Google Sign-In cancelled"))
                        return
                    }

                    let remaining = deadline.timeIntervalSinceNow
                    if remaining <= 0 {
                        continuation.resume(throwing: GoogleDriveError.oauthFailed("Timed out waiting for browser OAuth callback"))
                        return
                    }

                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let stepMs = Int32(min(250, max(1, Int(remaining * 1000))))
                    let ready = Darwin.poll(&pfd, 1, stepMs)

                    if self.isCancelled() {
                        continuation.resume(throwing: GoogleDriveError.oauthFailed("Google Sign-In cancelled"))
                        return
                    }
                    if ready < 0 {
                        if errno == EINTR { continue }
                        continuation.resume(throwing: GoogleDriveError.oauthFailed("Loopback poll failed"))
                        return
                    }
                    if ready == 0 {
                        continue
                    }

                    var clientAddr = sockaddr_in()
                    var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            Darwin.accept(fd, sockPtr, &clientLen)
                        }
                    }
                    guard clientFD >= 0 else {
                        if self.isCancelled() {
                            continuation.resume(throwing: GoogleDriveError.oauthFailed("Google Sign-In cancelled"))
                        } else if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                            continue
                        } else {
                            continuation.resume(throwing: GoogleDriveError.oauthFailed("Failed to accept loopback connection"))
                        }
                        return
                    }

                    var rcvTimeout = timeval(tv_sec: 5, tv_usec: 0)
                    _ = setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &rcvTimeout, socklen_t(MemoryLayout<timeval>.size))
                    var sndTimeout = timeval(tv_sec: 5, tv_usec: 0)
                    _ = setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &sndTimeout, socklen_t(MemoryLayout<timeval>.size))

                    var buffer = [UInt8](repeating: 0, count: 8192)
                    let bytesRead = Darwin.read(clientFD, &buffer, buffer.count - 1)
                    guard bytesRead > 0 else {
                        // Browser speculative preconnect with no HTTP request yet; keep waiting.
                        Darwin.close(clientFD)
                        continue
                    }

                    let rawRequest = String(decoding: buffer.prefix(bytesRead), as: UTF8.self)
                    let (method, requestTarget) = Self.extractRequestLine(from: rawRequest)
                    let pathOnly = Self.extractPathOnly(from: requestTarget)

                    if method != "GET" {
                        Self.writeEmptyHTTPStatus(405, reason: "Method Not Allowed", to: clientFD)
                        Darwin.close(clientFD)
                        continue
                    }
                    if pathOnly != "/oauth2callback" {
                        Self.writeEmptyHTTPStatus(404, reason: "Not Found", to: clientFD)
                        Darwin.close(clientFD)
                        continue
                    }

                    defer { Darwin.close(clientFD) }
                    do {
                        let code = try Self.handleCallbackRequest(rawRequest, clientFD: clientFD, expectedState: expectedState)
                        continuation.resume(returning: code)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                    return
                }
            }
        }
    }

    public static func processClientFD(_ clientFD: Int32, expectedState: String) throws -> String {
        var rcvTimeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &rcvTimeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = Darwin.read(clientFD, &buffer, buffer.count - 1)
        guard bytesRead > 0 else {
            throw GoogleDriveError.oauthFailed("Empty request on loopback callback")
        }
        let rawRequest = String(decoding: buffer.prefix(bytesRead), as: UTF8.self)
        return try handleCallbackRequest(rawRequest, clientFD: clientFD, expectedState: expectedState)
    }

    public static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func extractRequestLine(from rawRequest: String) -> (method: String, target: String) {
        let firstLine = rawRequest.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        let method = parts.first.map { String($0).uppercased() } ?? ""
        let target = parts.count >= 2 ? String(parts[1]) : "/"
        return (method, target)
    }

    private static func extractPathOnly(from target: String) -> String {
        if let qIdx = target.firstIndex(of: "?") {
            return String(target[..<qIdx])
        }
        return target
    }

    private static func writeEmptyHTTPStatus(_ status: Int, reason: String, to clientFD: Int32) {
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nX-Content-Type-Options: nosniff\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        _ = header.withCString { ptr in
            Darwin.write(clientFD, ptr, strlen(ptr))
        }
    }

    private static func writeHTMLResponse(status: Int, reason: String, html: String, to clientFD: Int32) {
        let response = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(html.utf8.count)",
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
            "X-Content-Type-Options: nosniff",
            "X-Frame-Options: DENY",
            "Cache-Control: no-store",
            "Connection: close",
            "",
            html
        ].joined(separator: "\r\n")
        _ = response.withCString { ptr in
            Darwin.write(clientFD, ptr, strlen(ptr))
        }
    }

    private static func handleCallbackRequest(_ rawRequest: String, clientFD: Int32, expectedState: String) throws -> String {
        let (method, requestTarget) = extractRequestLine(from: rawRequest)
        let pathOnly = extractPathOnly(from: requestTarget)

        do {
            guard method == "GET", pathOnly == "/oauth2callback" else {
                throw GoogleDriveError.oauthFailed("Unexpected OAuth callback method or path")
            }
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
            writeHTMLResponse(status: 200, reason: "OK", html: html, to: clientFD)
            return code
        } catch {
            let safeError = escapeHTML(error.localizedDescription)
            let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Authentication Error</title></head><body><h3>Authentication Error</h3><p>\(safeError)</p></body></html>"
            writeHTMLResponse(status: 400, reason: "Bad Request", html: html, to: clientFD)
            throw error
        }
    }
}
