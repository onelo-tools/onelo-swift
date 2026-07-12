import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// LRU buffer of recent feature-flag evaluations. Attached to every captured
/// error so devs can answer "was this error correlated with flag X being
/// enabled?". This is Onelo's killer feature — Sentry has it, but Sentry
/// doesn't know about Onelo flags. We do.
///
/// Capacity 100: matches Sentry's default. Smaller buffers (e.g. 10) drop
/// flags too aggressively to be useful.
public struct MonitorFlagSnapshot: Encodable, Sendable {
    public let key: String
    public let value: String   // stringified — supports bool, string, and JSON for variants
}

final class MonitorFeatureFlagBuffer: @unchecked Sendable {
    private struct Entry {
        let value: String
        // Monotonically increasing insertion order. We previously used `Date`
        // here, but two consecutive `Date()` calls within the same microsecond
        // can produce identical timestamps — making LRU eviction non-deterministic
        // and `sorted(by: <)` order undefined. A simple Int counter gives a
        // total order even under tight loops.
        let order: UInt64
    }

    private var storage: [String: Entry] = [:]
    private var counter: UInt64 = 0
    private let capacity: Int
    private var lock = os_unfair_lock()

    init(capacity: Int = 100) {
        self.capacity = capacity
    }

    func record(_ key: String, value: String) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        counter &+= 1
        storage[key] = Entry(value: value, order: counter)
        if storage.count > capacity {
            // Evict the oldest by insertion order. O(n) but n ≤ 100.
            if let oldest = storage.min(by: { $0.value.order < $1.value.order }) {
                storage.removeValue(forKey: oldest.key)
            }
        }
    }

    func snapshot() -> [MonitorFlagSnapshot] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return storage
            .sorted { $0.value.order < $1.value.order }
            .map { MonitorFlagSnapshot(key: $0.key, value: $0.value.value) }
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        storage.removeAll()
    }
}
