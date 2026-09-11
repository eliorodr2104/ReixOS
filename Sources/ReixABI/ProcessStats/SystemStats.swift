//
//  SystemStats.swift
//  ReixOS
//
//  Created by Eliomar on 22/08/2026.
//


/// Machine-wide metrics the kernel fills in for `procStats` sub-operation 0,
/// and the record the profiler's export page republishes.
///
/// 96 bytes, aligned members in declaration order, so a syscall or the SHM
/// exporter writes it with one struct store and a userland reader loads it back
/// the same way. `availability` says which groups below were measured at all;
/// a group whose bit is clear reads zero and means "not measured", never zero.
///
/// Units and accounting domains, per group:
///   * physical pages: PPM frames of `TaskABI.pageSize`, machine-wide.
///   * kernel heap bytes: `live` is rounded allocation capacity and not bytes
///     asked for, `reserved` is the physical backing behind the allocator.
///   * timer frequency: Hz of the generic timer.
///   * stack bytes: high-water marks from the poison scan, against the spans
///     the linker reserved.
///   * PMU: counts of implemented counters and of advertised events. Cycles
///     themselves are raw and are never converted with the timer frequency.
@frozen
public struct SystemStats {

    public var physicalTotalPages    : UInt64 = 0 // 0
    public var physicalAllocatedPages: UInt64 = 0 // 8
    public var physicalFreePages     : UInt64 = 0 // 16

    public var kernelHeapLiveBytes             : UInt64 = 0 // 24
    public var kernelHeapLiveHighWaterBytes    : UInt64 = 0 // 32
    public var kernelHeapReservedBytes         : UInt64 = 0 // 40
    public var kernelHeapReservedHighWaterBytes: UInt64 = 0 // 48

    public var timerFrequency: UInt64 = 0 // 56 Hz
    public var traceLost     : UInt64 = 0 // 64 events

    public var availability           : UInt32 = 0 // 72
    public var kernelStackUsedBytes   : UInt32 = 0 // 76
    public var kernelStackCapacity    : UInt32 = 0 // 80
    public var exceptionStackUsedBytes: UInt32 = 0 // 84
    public var exceptionStackCapacity : UInt32 = 0 // 88
    public var pmuEventAvailability   : UInt16 = 0 // 92
    public var pmuEventCounters       : UInt16 = 0 // 94

    public init() {}
}


/// Bit assignments for `SystemStats.availability`.
public enum SystemMetricAvailability {
    public static let physicalMemory : UInt32 = 1 << 0
    public static let kernelHeap     : UInt32 = 1 << 1
    public static let stacks         : UInt32 = 1 << 2
    public static let timer          : UInt32 = 1 << 3
    public static let pmuCycleCounter: UInt32 = 1 << 4
}

/// Bit assignments for `SystemStats.pmuEventAvailability`.
public enum PMUEventAvailability {
    /// Architectural event 0x08, INST_RETIRED, is advertised by PMCEID0_EL0.
    public static let instructionsRetired: UInt16 = 1 << 0
}


/// Page 0 of the profiler's export region, as both sides read it.
///
/// The kernel writes the snapshot under a seqlock at `sequenceOffset` and
/// userland reads it back; the offsets are derived from the records so a field
/// added to either one moves both readers together.
public enum StatsExportPage {
    public static let sequenceOffset     = 0
    public static let systemOffset       = 8
    public static let processCountOffset = systemOffset + MemoryLayout<SystemStats>.stride
    public static let processSlotsOffset = processCountOffset + 8
    public static let processSlotStride  = MemoryLayout<ProcessStats>.stride

    /// Slots the kernel publishes. The page holds far more; this is what the
    /// tick is willing to spend on the walk.
    public static let processSlotLimit = 16
}
