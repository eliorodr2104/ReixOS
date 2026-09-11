//
//  Export.swift
//  ReixOS
//
//  Created by Eliomar on 04/08/2026.
//


import Reix

/// Bounded consumer over the profiler's SHM export: page 0 is a seqlock'd
/// snapshot of `SystemStats` plus a `ProcessStats` table, pages 1-3 are one
/// ring of fixed-size event records. Page 0's shape comes from
/// `StatsExportPage`; the ring's does not, because its record format is a wire
/// contract with the kernel's internal `TraceEvent`, which userland cannot
/// import.
enum Export {
    static let pageSize     = 4096
    static let ringPages    = 3

    /// The slots the kernel publishes in page 0, from the same declaration
    /// the kernel bounds its walk with.
    static let maxProcesses = StatsExportPage.processSlotLimit
}
