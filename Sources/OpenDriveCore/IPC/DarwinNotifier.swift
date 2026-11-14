import Foundation
import CoreFoundation

/// Cross-process IPC notification bus using `CFNotificationCenterGetDarwinNotifyCenter()`
/// between `OpenDriveApp` and `OpenDriveFS`.
public enum DarwinSignal: String, Sendable, CaseIterable {
    case signal       = "com.opendrive.signal"
    case changed      = "com.opendrive.changed"
    case pulled       = "com.opendrive.pulled"
    case clearCache   = "com.opendrive.clearCache"
    case cancelUpload = "com.opendrive.cancelUpload"
    case staleNames   = "com.opendrive.staleNames"
    case ejectGuard   = "com.opendrive.ejectguard"
}

public final class DarwinNotifier: @unchecked Sendable {
    public static let shared = DarwinNotifier()

    private let lock = NSLock()
    private var handlers: [DarwinSignal: [UUID: @Sendable () -> Void]] = [:]
    private var registeredSignals: Set<DarwinSignal> = []

    private init() {}

    public func post(_ signal: DarwinSignal) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(signal.rawValue as CFString),
            nil,
            nil,
            true
        )
    }

    @discardableResult
    public func observe(_ signal: DarwinSignal, handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        var map = handlers[signal, default: [:]]
        map[id] = handler
        handlers[signal] = map
        let needsRegistration = !registeredSignals.contains(signal)
        if needsRegistration {
            registeredSignals.insert(signal)
        }
        lock.unlock()

        if needsRegistration {
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
            CFNotificationCenterAddObserver(
                center,
                observer,
                { _, observerPtr, name, _, _ in
                    guard let observerPtr,
                          let rawName = name?.rawValue as String?,
                          let sig = DarwinSignal(rawValue: rawName) else {
                        return
                    }
                    let instance = Unmanaged<DarwinNotifier>.fromOpaque(observerPtr).takeUnretainedValue()
                    instance.dispatch(sig)
                },
                signal.rawValue as CFString,
                nil,
                .deliverImmediately
            )
        }
        return id
    }

    public func removeObserver(_ id: UUID, for signal: DarwinSignal) {
        lock.lock()
        handlers[signal]?.removeValue(forKey: id)
        lock.unlock()
    }

    private func dispatch(_ signal: DarwinSignal) {
        lock.lock()
        let callbacks = Array((handlers[signal] ?? [:]).values)
        lock.unlock()
        for callback in callbacks {
            callback()
        }
    }
}
