import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

/// Crash capture aggregator. v1 uses two complementary sources:
///
///   1. **NSSetUncaughtExceptionHandler** — catches Objective-C exceptions
///      (NSInvalidArgumentException, etc.). These are typically the only
///      crashes you can recover information from in-process. We chain to
///      any pre-existing handler so we don't break other SDKs.
///   2. **MetricKit (`MXCrashDiagnostic`)** — Apple's official, on-device
///      crash diagnostics framework (iOS 14+, macOS 12+). Delivered next
///      launch, opted-in per user, asynchronous. Captures crashes that
///      NSException doesn't (signals, async hangs, OOM).
///
/// Why no PLCrashReporter in v1: external SPM dependency on
/// github.com/microsoft/plcrashreporter would risk build failures in
/// offline / CI-restricted environments and adds ObjC + C compile units.
/// Interface here is dependency-free; a future v2 can swap MetricKit-only
/// for PLCrashReporter without breaking callers.
final class MonitorCrashCapture: @unchecked Sendable {

    /// Whatever handler was installed *before* OneloMonitor — we call it
    /// after our own so 3rd-party SDKs that also install handlers don't
    /// get silently overridden.
    private static var previousHandler: (@convention(c) (NSException) -> Void)?

    /// **Strong** global reference so the C-style exception handler always
    /// finds a live instance — even if the host's `OneloMonitor` deinits.
    /// We trade a small memory footprint (one capture + closure) for
    /// guaranteed crash delivery, which would be worthless if the sink
    /// disappears mid-handler. Cleared explicitly via `uninstall()`.
    private static var globalSink: MonitorCrashCapture?

    /// Set to true once handlers are installed so `uninstall()` is idempotent.
    private static var installed = false

    private let onCrash: (String, [MonitorStackFrame], [String: String]) -> Void

    init(onCrash: @escaping (String, [MonitorStackFrame], [String: String]) -> Void) {
        self.onCrash = onCrash
    }

    deinit {
        // Remove MetricKit subscriber so we don't leak observers across
        // multi-instance scenarios. NSException handler can't be safely
        // restored from `deinit` (process may be mid-crash) — `uninstall()`
        // exists for explicit teardown.
        unsubscribeMetricKit()
    }

    /// Install handlers. Call once during SDK init.
    func install() {
        installNSExceptionHandler()
        installMetricKit()
    }

    /// Tear down. Call before discarding the host monitor — restores any
    /// previously-installed NSException handler and stops MetricKit.
    func uninstall() {
        guard MonitorCrashCapture.installed else { return }
        NSSetUncaughtExceptionHandler(MonitorCrashCapture.previousHandler)
        MonitorCrashCapture.previousHandler = nil
        MonitorCrashCapture.globalSink = nil
        MonitorCrashCapture.installed = false
        unsubscribeMetricKit()
    }

    // MARK: - NSException

    private func installNSExceptionHandler() {
        // Strong global ref — guaranteed to outlive the host's local monitor
        // until `uninstall()` is called.
        MonitorCrashCapture.globalSink = self
        // Preserve any handler that was already installed.
        MonitorCrashCapture.previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(MonitorCrashCapture.handleException)
        MonitorCrashCapture.installed = true
    }

    /// Called from C-style handler. Must be `@convention(c)`-compatible.
    private static let handleException: @convention(c) (NSException) -> Void = { exception in
        // Symbolicate via Apple's call-stack helper (always available).
        let frames: [MonitorStackFrame] = exception.callStackReturnAddresses.map { num in
            MonitorStackFrame(
                address: String(format: "0x%016llx", UInt64(num.uintValue)),
                symbol: nil,
                module: nil,
                offset: nil
            )
        }

        var data: [String: String] = [:]
        data["name"] = exception.name.rawValue
        if let reason = exception.reason {
            data["reason"] = MonitorScrubber.scrubText(reason) ?? reason
        }
        // userInfo can contain arbitrary objects — flatten only string keys
        // and scrubbed string values, drop anything else (no PII smuggling).
        if let userInfo = exception.userInfo as? [String: Any], !userInfo.isEmpty {
            var flat: [String: String] = [:]
            for (k, v) in userInfo {
                if let s = v as? String,
                   let scrubbed = MonitorScrubber.scrubText(s) {
                    flat[k] = scrubbed
                } else if let n = v as? NSNumber {
                    flat[k] = n.stringValue
                }
            }
            if let json = try? JSONSerialization.data(withJSONObject: flat),
               let str = String(data: json, encoding: .utf8) {
                data["userInfo"] = str
            }
        }

        let message = MonitorScrubber.scrubText(exception.reason ?? exception.name.rawValue)
            ?? exception.name.rawValue

        if let sink = globalSink {
            sink.onCrash(message, frames, data)
        }

        // Chain to whoever was installed before us so other SDKs / app
        // handlers still run.
        previousHandler?(exception)
    }

    // MARK: - MetricKit

    #if canImport(MetricKit)
    private var metricKitSubscriber: _MonitorMetricKitSubscriber?

    private func installMetricKit() {
        if #available(iOS 14.0, macOS 12.0, *) {
            let subscriber = _MonitorMetricKitSubscriber(onCrash: onCrash)
            MXMetricManager.shared.add(subscriber)
            self.metricKitSubscriber = subscriber
        }
    }

    private func unsubscribeMetricKit() {
        if #available(iOS 14.0, macOS 12.0, *) {
            if let sub = metricKitSubscriber {
                MXMetricManager.shared.remove(sub)
            }
        }
        metricKitSubscriber = nil
    }
    #else
    private func installMetricKit() { /* MetricKit unavailable on this platform */ }
    private func unsubscribeMetricKit() { /* MetricKit unavailable on this platform */ }
    #endif
}

#if canImport(MetricKit)

/// MetricKit subscriber — receives async diagnostic payloads on next launch.
@available(iOS 14.0, macOS 12.0, *)
final class _MonitorMetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    private let onCrash: (String, [MonitorStackFrame], [String: String]) -> Void

    init(onCrash: @escaping (String, [MonitorStackFrame], [String: String]) -> Void) {
        self.onCrash = onCrash
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        // We don't currently surface metrics-only payloads (CPU, memory,
        // network). Future enhancement.
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                handleCrash(crash)
            }
            for hang in payload.hangDiagnostics ?? [] {
                handleHang(hang)
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                handleCPU(cpu)
            }
        }
    }

    // MetricKit gives us a `callStackTree` JSON tree per diagnostic. We
    // forward the JSON as-is for backend symbolication (the tree references
    // binary UUIDs + offsets — backend resolves with the dev's dSYM).
    // `callStackTree` lives on each subclass, not on `MXDiagnostic` base.

    private func handleCrash(_ crash: MXCrashDiagnostic) {
        var data: [String: String] = ["kind": "crash", "source": "metrickit"]
        attachCallStackTree(crash.callStackTree, into: &data)
        data["terminationReason"] = crash.terminationReason ?? ""
        data["signal"] = crash.signal?.stringValue ?? ""
        data["exceptionType"] = crash.exceptionType?.stringValue ?? ""
        data["exceptionCode"] = crash.exceptionCode?.stringValue ?? ""
        if let region = crash.virtualMemoryRegionInfo {
            data["virtualMemoryRegion"] = region
        }
        let message = "[MetricKit:crash] \(data["terminationReason"] ?? "")"
        onCrash(message, [], data)
    }

    private func handleHang(_ hang: MXHangDiagnostic) {
        var data: [String: String] = ["kind": "hang", "source": "metrickit"]
        attachCallStackTree(hang.callStackTree, into: &data)
        data["hangDuration"] = String(hang.hangDuration.value)
        onCrash("[MetricKit:hang]", [], data)
    }

    private func handleCPU(_ cpu: MXCPUExceptionDiagnostic) {
        var data: [String: String] = ["kind": "cpu_exception", "source": "metrickit"]
        attachCallStackTree(cpu.callStackTree, into: &data)
        data["totalCPUTime"] = String(cpu.totalCPUTime.value)
        data["totalSampledTime"] = String(cpu.totalSampledTime.value)
        onCrash("[MetricKit:cpu]", [], data)
    }

    private func attachCallStackTree(_ tree: MXCallStackTree, into data: inout [String: String]) {
        let treeData = tree.jsonRepresentation()
        if let str = String(data: treeData, encoding: .utf8) {
            data["callStackTree"] = str
        }
    }
}

#endif
