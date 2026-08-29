//
//  CapRights.swift
//  ReixOS
//

public struct CapRights: OptionSet {

    /// Sixteen bits, of which eight are spoken for. It was eight, all spoken
    /// for, which is why three of them below are shared between a memory
    /// meaning and a profiling one. Widening it costs nothing: the word already
    /// travelled as a `UInt32` in `CapGrant` and as a register in every syscall
    /// that carries rights, and it was only this type that was narrow.
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
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

    /// The legacy profiling authorities together: statistics, console and
    /// counters. This intentionally excludes `.profileMark`; the root receives
    /// it separately and attenuates interaction marking as its own authority.
    public static let profile = CapRights(rawValue: (1 << 5) | (1 << 6) | (1 << 7))


    /// May turn a device window into a physical address, by minting a DMA
    /// buffer through it.
    ///
    /// Held apart from `write` because they are not the same authority, even
    /// though one used to imply the other here. Writing a device's registers
    /// drives that device; a physical address, on a machine with nothing between
    /// a device and memory, is the whole of RAM. Most devices never transfer on
    /// their own - a UART does not - and a driver for one has no business
    /// holding the second authority just because it holds the first.
    ///
    /// Whoever cuts the capability decides. A bus carries this and passes it to
    /// every window it carves, and the process that hands a window to a driver
    /// says then and there whether the driver gets it.
    public static let dma = CapRights(rawValue: 1 << 8)

    /// File one interaction mark only. This does not authorize profile
    /// control, trace dumping, or process and counter statistics.
    public static let profileMark = CapRights(rawValue: 1 << 9)
}
