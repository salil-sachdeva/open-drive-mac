import Foundation
import Network

/// Observes live `NWPathMonitor` changes to pause/resume uploads on metered (hotspot) or offline networks.
public final class NetworkPathObserver: @unchecked Sendable {
    public static let shared = NetworkPathObserver()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "org.opendrive.networkMonitor", qos: .utility)
    private let lock = NSLock()
    private var isStarted = false
    public private(set) var isMetered: Bool = false
    public private(set) var isOffline: Bool = false
    private var listeners: [UUID: @Sendable (Bool, Bool) -> Void] = [:]

    private init() {}

    @discardableResult
    public func observe(_ handler: @escaping @Sendable (_ isMetered: Bool, _ isOffline: Bool) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        listeners[id] = handler
        let currentMetered = isMetered
        let currentOffline = isOffline
        let shouldStart = !isStarted
        if shouldStart {
            isStarted = true
        }
        lock.unlock()

        handler(currentMetered, currentOffline)

        if shouldStart {
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                let metered = path.isExpensive || path.isConstrained
                let offline = path.status != .satisfied
                self.lock.lock()
                self.isMetered = metered
                self.isOffline = offline
                let callbacks = Array(self.listeners.values)
                self.lock.unlock()
                for cb in callbacks {
                    cb(metered, offline)
                }
            }
            monitor.start(queue: queue)
        }
        return id
    }
}
