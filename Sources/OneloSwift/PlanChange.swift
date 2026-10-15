import Foundation

/// A Store Hand-back that moved the plan (#659): a purchase, or a plan switch
/// with the store's reason (`plan_switched` | `switch_scheduled` |
/// `plan_switch_pending`).
///
/// The hosted store / Customer Portal only closes its container. Waiting for
/// the Event Stream left the app on the old plan for about a minute, so every
/// container reports the change to `OneloAuth.reportPlanChange`, and `Onelo`
/// reconciles at once through ``PlanChangeRefresher``. The live complement is
/// the stream's `paywall.access_changed` (#635).
public enum OneloPlanChange: Equatable, Sendable {
    case purchase
    case switched(reason: String)

    /// The plan change a hand-back carries, or nil when it cannot move the plan
    /// (the portal's own Done, an error).
    init?(_ handBack: HandBack) {
        switch handBack {
        case .purchase: self = .purchase
        case .switched(let reason): self = .switched(reason: reason)
        case .portalClosed, .error: return nil
        }
    }
}

/// The store's reason for a paid switch Stripe has not applied yet (#615).
let planSwitchPendingReason = "plan_switch_pending"

/// Gaps between re-checks after `plan_switch_pending`: ~30 s in all.
let pendingRecheckDelaysSeconds: [Double] = [1, 2, 4, 8, 15]

/// The ONE place the SDK reacts to "the buyer just bought or switched a plan":
/// a forced REST re-resolve of the features (past the 1 s debounce) and a
/// re-read of the entitlement. A `plan_switch_pending` switch is re-checked on
/// a bounded backoff until the features snapshot differs from the one before
/// the hand-back, or the delays run out. Same shape as `@onelo/js`
/// `core/plan-change.ts`.
@MainActor
final class PlanChangeRefresher {
    private let refreshFeatures: () async -> Void
    private let revalidateEntitlement: () async -> Void
    private let snapshot: () -> String
    private let delays: [Double]
    private let sleep: (Double) async -> Void
    private var generation = 0
    /// The running re-check loop, if any. Internal so a test can await it.
    private(set) var recheckTask: Task<Void, Never>?

    init(
        refreshFeatures: @escaping () async -> Void,
        revalidateEntitlement: @escaping () async -> Void,
        snapshot: @escaping () -> String,
        delays: [Double] = pendingRecheckDelaysSeconds,
        sleep: @escaping (Double) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.refreshFeatures = refreshFeatures
        self.revalidateEntitlement = revalidateEntitlement
        self.snapshot = snapshot
        self.delays = delays
        self.sleep = sleep
    }

    /// Reconcile after a hand-back. Returns once the immediate refresh is done;
    /// a pending switch keeps re-checking in ``recheckTask``.
    func handBack(_ change: OneloPlanChange) async {
        generation += 1
        let current = generation
        recheckTask?.cancel()
        recheckTask = nil
        let before = snapshot()
        await refreshFeatures()
        await revalidateEntitlement()
        guard case .switched(let reason) = change, reason == planSwitchPendingReason,
              current == generation else { return }
        recheckTask = Task { [weak self] in await self?.recheck(current, before: before) }
    }

    /// Stop any pending re-checks (SDK teardown / sign-out).
    func cancel() {
        generation += 1
        recheckTask?.cancel()
        recheckTask = nil
    }

    private func recheck(_ current: Int, before: String) async {
        for delay in delays {
            guard current == generation, snapshot() == before else { return }
            await sleep(delay)
            guard !Task.isCancelled, current == generation else { return }
            await refreshFeatures()
            guard current == generation else { return }
            if snapshot() != before {
                await revalidateEntitlement()
                return
            }
        }
    }
}
