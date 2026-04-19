import Foundation

/// One symbolicated frame in a backtrace, parsed from xctrace's `time-profile`
/// table (see `<frame name="…" addr="…">` in the export XML).
struct TimeProfileFrame: Sendable, Hashable {
    let symbol: String
    let address: UInt64
    let module: String?
}

/// One CPU profiling sample, time-stamped, with the full call stack.
/// Backtrace is **leaf-first** as exported by xctrace.
struct TimeProfileSample: Sendable {
    let timestampNs: UInt64
    let weightNs: UInt64
    let backtrace: [TimeProfileFrame]
}

/// All samples for a single thread, ordered by timestamp.
struct TimeProfileThread: Sendable, Identifiable {
    let id: UInt64           // tid
    let label: String
    let samples: [TimeProfileSample]
}

/// Result of parsing an xctrace `.trace` bundle.
struct TimeProfileTrace: Sendable {
    let startNs: UInt64
    let endNs: UInt64
    let threads: [TimeProfileThread]
    var durationNs: UInt64 { endNs > startNs ? endNs - startNs : 0 }
}
