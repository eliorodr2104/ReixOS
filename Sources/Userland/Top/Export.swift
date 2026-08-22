//
//  Export.swift
//  ReixOS
//
//  Created by Eliomar on 04/08/2026.
//


/// Bounded consumer over the profiler's SHM export: page 0 is a seqlock'd
/// snapshot of `SystemStats` plus a `ProcessStats` table, pages 1-3 are one
/// ring of fixed-size event records. Neither layout is a shared Swift type
/// because the ring's record format is a wire contract with the kernel's
/// internal `TraceEvent`, which userland cannot import.
enum Export {
    static let pageSize     = 4096
    static let ringPages    = 3

    /// Matches the kernel's own `TraceExport.processLimit`: page 0 has room
    /// for exactly this many `ProcessStats` slots.
    static let maxProcesses = 16
}
