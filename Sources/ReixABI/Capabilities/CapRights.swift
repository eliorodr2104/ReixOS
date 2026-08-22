//
//  CapRights.swift
//  ReixOS
//

public struct CapRights: OptionSet {

    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let send    = CapRights(rawValue: 1 << 0)
    public static let receive = CapRights(rawValue: 1 << 1)
    public static let grant   = CapRights(rawValue: 1 << 2)
    public static let spawn   = CapRights(rawValue: 1 << 3)
    public static let derive  = CapRights(rawValue: 1 << 4)

    public static let read    = CapRights(rawValue: 1 << 5)
    public static let write   = CapRights(rawValue: 1 << 6)

    /// Read the process table and the machine counters: the `procStats`
    /// syscall, and the export region `attachExport` publishes them into.
    public static let profileStats = CapRights(rawValue: 1 << 5)

    /// Walk the trace ring out of the console. A category of its own because
    /// a dump is a long stretch of polled UART writes, which starves every
    /// other process of the one console they share.
    public static let profileConsole = CapRights(rawValue: 1 << 6)

    /// The PMU block and the sampling machinery its counters drive: `pmuProbe`,
    /// the runtime class mask, the ring reset and the sample divider. The last
    /// three ride here for want of a fourth free bit, and they belong with the
    /// counters rather than with the readers: they arm the sampler.
    public static let profileCounters = CapRights(rawValue: 1 << 7)

    /// Every profiling category at once, which is what the boot profiler
    /// capability holds and what a tool spawned off it must be attenuated from.
    public static let profile = CapRights(rawValue: (1 << 5) | (1 << 6) | (1 << 7))
}
