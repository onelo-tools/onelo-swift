import Foundation

/// Install-bound identifier — a UUID that survives across app launches but
/// is wiped on uninstall. Used as `sessionId` so the dashboard can group
/// events by install instead of "every launch is a new session".
///
/// Why a file in Application Support (not Keychain, not UserDefaults):
///
/// - **Keychain** keeps items across uninstall on iOS until device wipe
///   (this is documented Apple behaviour, not a bug). For an *install*
///   identifier, that's wrong — a fresh install should look fresh.
/// - **UserDefaults** is scoped to the app bundle but can be backed up
///   into iCloud Backup, where it can survive a re-install. We don't want
///   that for diagnostic IDs.
/// - **File in Application Support with .completeUntilFirstUserAuthentication
///   protection** is wiped on uninstall and never leaves the device. This
///   matches the install-scoped semantics we want.
///
/// We deliberately do NOT use `identifierForVendor` (UIDevice) — it is a
/// stable cross-app identifier per vendor and triggers App Store fingerprint
/// scrutiny. Our UUID is per-install per-app, opaque, and reset on reinstall.
enum MonitorInstallID {
    private static let filename = "onelo_monitor_install_id"

    /// Serial queue serialising read/write of the install-id file across all
    /// callers. Without it, two concurrent first-launch initialisations could
    /// each write a fresh UUID and one would win-then-lose, returning the
    /// orphan to its caller. In-process only — multi-process coordination
    /// would need flock(2), which iOS sandboxing makes unnecessary in
    /// practice (one process per app).
    private static let queue = DispatchQueue(label: "com.onelo.monitor.installid")

    /// Returns the install ID, generating and persisting one if needed.
    /// Falls back to an in-memory UUID if persistence fails so monitor
    /// keeps working even when disk is unwritable.
    static func get() -> String {
        queue.sync {
            if let url = fileURL(), let stored = read(from: url) {
                return stored
            }
            let new = UUID().uuidString
            if let url = fileURL() {
                try? write(new, to: url)
            }
            return new
        }
    }

    // MARK: - Internal

    private static func fileURL() -> URL? {
        let fm = FileManager.default
        guard var dir = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        // Namespace under our bundle so multi-target setups don't collide.
        let ns = Bundle.main.bundleIdentifier ?? "onelo"
        dir = dir.appendingPathComponent(ns, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent(filename)
    }

    private static func read(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func write(_ value: String, to url: URL) throws {
        guard let data = value.data(using: .utf8) else { return }
        // .completeUntilFirstUserAuthentication: readable after first unlock,
        // even when the device is later locked. Required so we can flush
        // queued events from background tasks.
        var options: Data.WritingOptions = [.atomic]
        #if canImport(UIKit)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: url, options: options)
    }
}
