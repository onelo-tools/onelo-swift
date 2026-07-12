import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// Device-wide context attached to monitor events.
///
/// Privacy-critical decisions:
///
/// - **No `identifierForVendor`** — too fingerprintable; would trigger
///   App Store privacy scrutiny.
/// - **No free disk space** — would require declaring `7D9E.1` reason in
///   PrivacyInfo.xcprivacy and the only valid reason is "display free space
///   to the user", which doesn't apply to background monitoring.
/// - **No system boot time / uptime** — privacy manifest hassle, low value.
/// - **No battery level** — historically used for cross-app fingerprinting.
/// - **Locale and timezone** are coarse-grained (region, not city) and are
///   considered standard diagnostic context (Sentry/PostHog default).
public struct MonitorDeviceContext: Encodable, Sendable {
    public let model: String         // "iPhone15,3" / "MacBookPro18,3"
    public let os: String            // "iOS 19.2" / "macOS 14.5"
    public let locale: String        // "pl_PL"
    public let timezone: String      // "Europe/Warsaw"
    public let memoryMB: Int         // total physical, MB
    public let lowPowerMode: Bool    // iOS only; false on macOS
    public let connection: String    // "wifi" | "cellular" | "wired" | "loopback" | "none"
}

/// Lightweight, lazy device context provider. Captured once at SDK init,
/// connection refreshed live by `NWPathMonitor`.
final class MonitorDeviceContextProvider: @unchecked Sendable {
    private let pathMonitor: NWPathMonitor
    private let pathQueue = DispatchQueue(label: "com.onelo.monitor.path")
    private var currentConnection: String = "unknown"
    private var lock = os_unfair_lock()

    init() {
        pathMonitor = NWPathMonitor()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.updateConnection(from: path)
        }
        pathMonitor.start(queue: pathQueue)
    }

    deinit {
        pathMonitor.cancel()
    }

    /// Lightweight, immutable subset (model/os/locale/timezone). Captured once
    /// per process — these do not change between launches. Attached to every
    /// monitor event so the Session Timeline always has minimum context.
    lazy var staticSnapshot: (model: String, os: String, locale: String, timezone: String) = {
        var sysinfo = utsname()
        uname(&sysinfo)
        let model: String = withUnsafePointer(to: &sysinfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        #if os(iOS)
        let osName = "iOS"
        #elseif os(macOS)
        let osName = "macOS"
        #elseif os(tvOS)
        let osName = "tvOS"
        #elseif os(watchOS)
        let osName = "watchOS"
        #else
        let osName = "Apple"
        #endif
        return (model, "\(osName) \(osVersion)", Locale.current.identifier, TimeZone.current.identifier)
    }()

    func snapshot() -> MonitorDeviceContext {
        let stat = staticSnapshot

        let memoryMB = Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024)

        let lowPower: Bool
        #if os(iOS)
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        #else
        lowPower = false
        #endif

        os_unfair_lock_lock(&lock)
        let conn = currentConnection
        os_unfair_lock_unlock(&lock)

        return MonitorDeviceContext(
            model: stat.model,
            os: stat.os,
            locale: stat.locale,
            timezone: stat.timezone,
            memoryMB: memoryMB,
            lowPowerMode: lowPower,
            connection: conn
        )
    }

    private func updateConnection(from path: NWPath) {
        let value: String
        switch path.status {
        case .satisfied:
            if path.usesInterfaceType(.wifi) { value = "wifi" }
            else if path.usesInterfaceType(.cellular) { value = "cellular" }
            else if path.usesInterfaceType(.wiredEthernet) { value = "wired" }
            else if path.usesInterfaceType(.loopback) { value = "loopback" }
            else { value = "other" }
        case .unsatisfied: value = "none"
        case .requiresConnection: value = "requires"
        @unknown default: value = "unknown"
        }
        os_unfair_lock_lock(&lock)
        currentConnection = value
        os_unfair_lock_unlock(&lock)
    }
}
