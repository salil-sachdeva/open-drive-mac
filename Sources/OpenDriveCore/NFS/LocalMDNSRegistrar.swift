import dnssd
import Foundation

private final class RegisterContext: @unchecked Sendable {
    private let lock = NSLock()
    let semaphore = DispatchSemaphore(value: 0)
    private var signaled = false
    private(set) var errorCode: DNSServiceErrorType = DNSServiceErrorType(kDNSServiceErr_Unknown)

    func complete(error: DNSServiceErrorType) {
        lock.withLock {
            guard !signaled else { return }
            signaled = true
            errorCode = error
            semaphore.signal()
        }
    }
}

private let mdnsRegisterCallback: DNSServiceRegisterRecordReply = { _, _, _, errorCode, context in
    guard let context else { return }
    let box = Unmanaged<RegisterContext>.fromOpaque(context).takeUnretainedValue()
    box.complete(error: errorCode)
}

/// Registers a strictly local-only mDNS A record (`127.0.0.1`) so Finder and
/// `mount_nfs` display a friendly server name (`Open-Drive.local`) rather than
/// `127.0.0.1` without broadcasting anything on the local network.
public final class LocalMDNSRegistrar: @unchecked Sendable {
    public let hostname: String

    private let lock = NSLock()
    private var sdRef: DNSServiceRef?
    private var recordRef: DNSRecordRef?
    private var activeContextPointer: UnsafeMutableRawPointer?
    private let queue = DispatchQueue(label: "org.opendrive.mac.mdns")

    public init(hostname: String = "Open-Drive.local") {
        self.hostname = hostname
    }

    deinit {
        stop()
    }

    /// Registers `hostname -> 127.0.0.1` via local-only mDNS and returns the usable
    /// hostname (falling back to `"localhost"` if mDNS registration fails).
    @discardableResult
    public func start() -> String {
        lock.withLock {
            startLocked().host
        }
    }

    /// Waits for `mDNSResponder` to confirm registration before querying `getaddrinfo`,
    /// avoiding negative DNS caching (`EAI_NONAME`); falls back to `"localhost"` on timeout or error.
    public func startAndResolve(timeoutSeconds: Double = 2.0) -> String {
        let (candidate, context) = lock.withLock {
            startLocked()
        }
        guard candidate != "localhost", let context else { return "localhost" }

        let waitResult = context.semaphore.wait(timeout: .now() + timeoutSeconds)
        guard waitResult == .success, context.errorCode == kDNSServiceErr_NoError else {
            return "localhost"
        }

        for attempt in 0..<5 {
            if Self.resolvesToLoopback(candidate) {
                return candidate
            }
            if attempt < 4 {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return "localhost"
    }

    /// Resolves an RFC 6761 loopback subdomain (e.g. `Open-Drive.localhost`) to `127.0.0.1`
    /// without using multicast DNS or triggering macOS Local Network Privacy prompts.
    /// Falls back to `"localhost"` if the preferred host does not resolve to IPv4 loopback.
    public static func resolveLoopbackHostname(preferred: String = "Open-Drive.localhost") -> String {
        resolvesToLoopback(preferred) ? preferred : "localhost"
    }

    public static func loopbackHostname(forDriveName driveName: String) -> String {
        var label = ""
        var prevHyphen = false
        for ch in driveName {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                label.append(ch)
                prevHyphen = false
            } else if !prevHyphen && !label.isEmpty {
                label.append("-")
                prevHyphen = true
            }
            if label.count >= 48 {
                break
            }
        }
        while label.hasSuffix("-") {
            label.removeLast()
        }
        if label.isEmpty {
            label = "Open-Drive"
        }
        return "\(label).localhost"
    }

    public func stop() {
        lock.withLock {
            stopLocked()
        }
    }

    private func startLocked() -> (host: String, context: RegisterContext?) {
        stopLocked()

        var connRef: DNSServiceRef?
        let connErr = DNSServiceCreateConnection(&connRef)
        guard connErr == kDNSServiceErr_NoError, let activeConn = connRef else {
            return ("localhost", nil)
        }

        let contextBox = RegisterContext()
        let rawContext = Unmanaged.passRetained(contextBox).toOpaque()

        var recRef: DNSRecordRef?
        var loopbackIP: [UInt8] = [127, 0, 0, 1]
        let regErr = DNSServiceRegisterRecord(
            activeConn,
            &recRef,
            DNSServiceFlags(kDNSServiceFlagsShared),
            UInt32(kDNSServiceInterfaceIndexLocalOnly),
            hostname,
            UInt16(kDNSServiceType_A),
            UInt16(kDNSServiceClass_IN),
            4,
            &loopbackIP,
            120,
            mdnsRegisterCallback,
            rawContext
        )

        guard regErr == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(activeConn)
            Unmanaged<RegisterContext>.fromOpaque(rawContext).release()
            return ("localhost", nil)
        }

        guard DNSServiceSetDispatchQueue(activeConn, queue) == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(activeConn)
            Unmanaged<RegisterContext>.fromOpaque(rawContext).release()
            return ("localhost", nil)
        }

        self.sdRef = activeConn
        self.recordRef = recRef
        self.activeContextPointer = rawContext
        return (hostname, contextBox)
    }

    private func stopLocked() {
        if let rec = recordRef, let ref = sdRef {
            DNSServiceRemoveRecord(ref, rec, 0)
            recordRef = nil
        }
        if let ref = sdRef {
            DNSServiceRefDeallocate(ref)
            sdRef = nil
        }
        if let ptr = activeContextPointer {
            activeContextPointer = nil
            // Defer release onto the serial callback queue so any in-flight callback completes safely first.
            queue.async {
                Unmanaged<RegisterContext>.fromOpaque(ptr).release()
            }
        }
    }

    private static func resolvesToLoopback(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let head = result else { return false }
        defer { freeaddrinfo(head) }

        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let entry = cursor {
            if entry.pointee.ai_family == AF_INET, let sockAddr = entry.pointee.ai_addr {
                let sin = sockAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                if UInt32(bigEndian: sin.sin_addr.s_addr) == INADDR_LOOPBACK {
                    return true
                }
            }
            cursor = entry.pointee.ai_next
        }
        return false
    }
}
