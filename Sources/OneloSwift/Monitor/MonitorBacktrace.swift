import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Captures non-fatal stack traces using only public Swift / Darwin APIs.
///
/// For *fatal* crashes we rely on PLCrashReporter (signal-safe, full DWARF
/// unwinding, see `MonitorCrashReporter`). This file is for live errors —
/// `try/catch` around a network call, a Swift `Error` thrown from `async`,
/// `assertionFailure` in debug, etc.
///
/// We deliberately do NOT call private demangling APIs (`_stdlib_demangleName`)
/// — App Store review flags those and they are fragile across Swift versions.
/// Symbolication is performed server-side using the dSYM uploaded by the dev.
public struct MonitorStackFrame: Encodable {
    /// Frame address as a hex string (e.g. "0x000000010ab84c20").
    public let address: String
    /// Symbol name as Darwin reports it (often mangled; backend demangles).
    public let symbol: String?
    /// Loaded image / binary name (e.g. "MyApp" or "OneloSwift").
    public let module: String?
    /// Offset within the symbol, if known.
    public let offset: Int?
}

enum MonitorBacktrace {
    /// Capture a backtrace for the current thread.
    ///
    /// - Parameters:
    ///   - skip: Number of leading frames to drop (default 2 — skips this
    ///           function and the one that called it).
    ///   - maxDepth: Hard ceiling on captured frames. Sentry default is 100;
    ///               we use 64 to keep payload small.
    static func capture(skip: Int = 2, maxDepth: Int = 64) -> [MonitorStackFrame] {
        let raw = Thread.callStackReturnAddresses
        guard !raw.isEmpty else { return [] }
        let frames = raw.dropFirst(skip).prefix(maxDepth)

        return frames.map { num -> MonitorStackFrame in
            let addr = num.uintValue

            #if canImport(Darwin)
            var info = Dl_info()
            if let ptr = UnsafeRawPointer(bitPattern: UInt(addr)),
               dladdr(ptr, &info) != 0 {
                let symbol: String? = info.dli_sname.flatMap { String(cString: $0) }
                let module: String? = info.dli_fname.flatMap {
                    URL(fileURLWithPath: String(cString: $0)).lastPathComponent
                }
                let offset: Int?
                if let saddr = info.dli_saddr {
                    offset = Int(addr) - Int(bitPattern: saddr)
                } else {
                    offset = nil
                }
                return MonitorStackFrame(
                    address: String(format: "0x%016llx", UInt64(addr)),
                    symbol: symbol,
                    module: module,
                    offset: offset
                )
            }
            #endif

            return MonitorStackFrame(
                address: String(format: "0x%016llx", UInt64(addr)),
                symbol: nil,
                module: nil,
                offset: nil
            )
        }
    }

    /// Compact textual representation of a backtrace for legacy `error: String`
    /// fields. One frame per line.
    static func format(_ frames: [MonitorStackFrame]) -> String {
        frames.enumerated().map { idx, f in
            let mod = f.module ?? "?"
            let sym = f.symbol ?? "?"
            let off = f.offset.map { " +\($0)" } ?? ""
            return "\(idx)  \(mod)  \(f.address)  \(sym)\(off)"
        }.joined(separator: "\n")
    }
}
