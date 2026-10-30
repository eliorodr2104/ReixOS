//
//  ProcStatsSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

import ReixABI

/// `procStats(op, cursor, buffer, authority)` syscall provider: the pull side of
/// the profiler, for a reader that wants numbers rather than a trace.
///
/// `x0` = the sub-operation, `x1` = its cursor, `x2` = a user buffer, `x3` =
/// the profiler capability handle. Operation 0 fills a `SystemStats`, operation
/// 1 walks the process table one `ProcessStats` at a time. `UInt64.max` is the
/// only failure value, and also the end of a process sweep.
///
/// The authority is not a formality. What this syscall hands out is the process
/// table itself, names, pids, cpu time and footprint included, so it answers to
/// `CapRights.profileStats` exactly like the export region that republishes it.
public struct ProcStatsSyscall: SyscallProvider {

    public static let number: SyscallNumber = .procStats

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let operation = StatsSubOperation(rawValue: frame.pointee.x0) else {
            frame.pointee.x0 = UInt64.max
            return
        }

        guard let authority = ProfileABI.authorityHandle(frame.pointee.x3),
              ProfileAuthorization.allowsCurrent(
                handle  : authority,
                category: .profileStats
              ) else {
            frame.pointee.x0 = UInt64.max
            return
        }

        switch operation {

            case .systemOperation:
                frame.pointee.x0 = reportSystem(
                    into   : frame.pointee.x2,
                    context: context
                )

            case .processOperation:
                frame.pointee.x0 = reportProcess(
                    after  : frame.pointee.x1,
                    into   : frame.pointee.x2
                )
        }
    }


    /// Fill the caller's `SystemStats`, answering `0` or `UInt64.max`.
    private static func reportSystem(
        into buffer: UInt64,
        context    : SyscallContext
    ) -> UInt64 {

        guard let record = userRecord(
            at  : buffer,
            size: MemoryLayout<SystemStats>.size
        ) else { return UInt64.max }

        record.assumingMemoryBound(to: SystemStats.self).pointee = systemSnapshot(
            ppm : context.ppm,
            heap: context.processManager.pointee.heap
        )

        return 0
    }


    /// Fill the caller's `ProcessStats` with the successor of `cursor`, and
    /// answer that process's pid.
    ///
    /// The buffer is validated before the search, so a bad pointer costs the
    /// same whether the sweep had anything left or not, and the two failures are
    /// reported as the one value the ABI has.
    private static func reportProcess(
        after cursor: UInt64,
        into  buffer: UInt64
    ) -> UInt64 {

        guard let record = userRecord(
            at  : buffer,
            size: MemoryLayout<ProcessStats>.size
        ) else { return UInt64.max }

        guard let process = ProcessStatsIndex.successor(after: cursor) else {
            return UInt64.max
        }

        record.assumingMemoryBound(to: ProcessStats.self).pointee = snapshot(
            of : process,
            now: Arch.Timer.counter()
        )

        return process.pointee.pid
    }


    /// The machine, as the ABI reports it.
    ///
    /// Every group is published with the availability bit that says it was
    /// measured, so a reader never has to decide whether a zero is a reading.
    /// The physical and heap figures are counters their owners already keep,
    /// which is why there is no walk here.
    ///
    /// `TraceExport` republishes this same record into its SHM page, and calls
    /// this: two writers of one wire record must not be two fillers of it.
    static func systemSnapshot(
        ppm : UnsafeMutablePointer<KernelPPM>,
        heap: UnsafeMutablePointer<KernelHeap>
    ) -> SystemStats {

        var stats = SystemStats()

        let total     = ppm.pointee.totalPages
        let allocated = ppm.pointee.allocatedPages

        if allocated <= total {
            stats.availability |= SystemMetricAvailability.physicalMemory
            stats.physicalTotalPages     = total
            stats.physicalAllocatedPages = allocated
            stats.physicalFreePages      = total - allocated

            stats.physicalQuarantinedPages   = DmaQuarantine.pages
            stats.physicalQuarantinedRegions = DmaQuarantine.regions
        }

        let live              = heap.pointee.metricsLiveBytes
        let liveHighWater     = heap.pointee.metricsLiveHighWaterBytes
        let reserved          = heap.pointee.metricsReservedBytes
        let reservedHighWater = heap.pointee.metricsReservedHighWaterBytes

        if live <= reserved, live <= liveHighWater, reserved <= reservedHighWater {
            stats.availability |= SystemMetricAvailability.kernelHeap
            stats.kernelHeapLiveBytes              = live
            stats.kernelHeapLiveHighWaterBytes     = liveHighWater
            stats.kernelHeapReservedBytes          = reserved
            stats.kernelHeapReservedHighWaterBytes = reservedHighWater
        }

        let timerFrequency = Arch.Timer.frequency()
        if timerFrequency > 0 {
            stats.availability |= SystemMetricAvailability.timer
            stats.timerFrequency = timerFrequency
        }

        stats.traceLost = TraceRing.lost

        let kernelStackCapacity = UInt32(
            min(StackUsage.kernelStackCapacity, UInt64(UInt32.max))
        )
        let exceptionStackCapacity = UInt32(
            min(StackUsage.exceptionStackCapacity, UInt64(UInt32.max))
        )
        if kernelStackCapacity > 0 && exceptionStackCapacity > 0 {
            stats.availability |= SystemMetricAvailability.stacks
            stats.kernelStackCapacity    = kernelStackCapacity
            stats.exceptionStackCapacity = exceptionStackCapacity
            stats.kernelStackUsedBytes = UInt32(
                min(StackUsage.kernelStack, UInt64(UInt32.max))
            )
            stats.exceptionStackUsedBytes = UInt32(
                min(StackUsage.exceptionStack, UInt64(UInt32.max))
            )
        }

        if AArch64PMU.initialized {
            stats.availability |= SystemMetricAvailability.pmuCycleCounter
            stats.pmuEventCounters = UInt16(
                min(AArch64PMU.eventCounters, UInt64(UInt16.max))
            )
            if AArch64PMU.instructionsRetiredAvailable {
                stats.pmuEventAvailability |= PMUEventAvailability.instructionsRetired
            }
        }

        return stats
    }


    /// One process, as the ABI reports it.
    ///
    /// The running process is charged its open slice against `now`, so a reader
    /// sampling twice sees time move for whoever is on the CPU instead of a
    /// value frozen until the next rotation.
    ///
    /// `scheduledAt` is reported for that one process only. A process taken off
    /// the CPU has it cleared by the rotation that charged its slice, but one
    /// killed while running is never rotated off, and a stale reading on a
    /// corpse would read as a slice still open.
    ///
    /// A corpse the parent has not reaped has lost its address space and its
    /// metadata, so both are read through an optional: a missing one costs the
    /// record its footprint or its name, never the walk.
    static func snapshot(
        of process: UnsafeMutablePointer<Process>,
        now       : UInt64
    ) -> ProcessStats {

        var stats = ProcessStats()

        var isRunning   = false
        var scheduledAt = process.pointee.scheduledAt

        if case .running = process.pointee.status, scheduledAt != 0 {
            isRunning = true

        } else { scheduledAt = 0 }

        var cpuTime = process.pointee.cpuTime
        if isRunning { cpuTime &+= now &- scheduledAt }

        stats.pid         = process.pointee.pid
        stats.cpuTime     = cpuTime
        stats.status      = statusCode(of: process.pointee.status)
        stats.scheduledAt = scheduledAt

        if let manager = process.pointee.addressSpace.vmaManager {
            let memory = manager.pointee.memoryMetrics()

            stats.availability = ProcessMetricAvailability.virtualExtent
                | ProcessMetricAvailability.mappedPages
                | ProcessMetricAvailability.stack

            stats.virtualExtentPages = memory.virtualExtentPages
            stats.mappedPages        = memory.mappedPages
            stats.stackExtentPages   = pageCount(memory.stackExtentPages)
            stats.stackCapacityPages = pageCount(memory.stackCapacityPages)
        }

        if let metadata = process.pointee.metadata {
            stats.nameLength = metadata.pointee.nameLength

            for index in 0..<stats.name.count {
                stats.name[index] = metadata.pointee.name[index]
            }
        }

        return stats
    }


    /// A stack page count on the wire. The whole stack window is 16383 pages,
    /// so the clamp is a guard against a nonsense reading, not a real ceiling.
    private static func pageCount(_ pages: UInt32) -> UInt16 {
        UInt16(min(pages, UInt32(UInt16.max)))
    }


    /// The scheduler state, mapped into the ABI's `ProcessStatusCode`.
    ///
    /// Written out rather than derived from a `RawRepresentable` conformance on
    /// `ProcessStatus`: two of its cases carry an endpoint pointer, so the enum
    /// cannot have a raw value.
    static func statusCode(of status: ProcessStatus) -> UInt8 {
        switch status {
            case .new                : ProcessStatusCode.new.rawValue
            case .ready              : ProcessStatusCode.ready.rawValue
            case .running            : ProcessStatusCode.running.rawValue
            case .waiting            : ProcessStatusCode.waiting.rawValue
            case .blockedOnSend(_)   : ProcessStatusCode.blockedOnSend.rawValue
            case .blockedOnReceive(_): ProcessStatusCode.blockedOnReceive.rawValue
            case .blockedOnReply     : ProcessStatusCode.blockedOnReply.rawValue
            case .terminated         : ProcessStatusCode.terminated.rawValue
        }
    }


    /// Validate a user record buffer and hand back the memory to fill.
    ///
    /// The alignment check is not dressing: this kernel is built with
    /// strict-align codegen, so the single struct store the callers make would
    /// take a data abort at EL1 on a buffer the caller placed off an 8-byte
    /// boundary, and EL1 has no fault fixup. A refusal is the only other answer.
    ///
    /// `validateRegion` also forces every page of the range into the page
    /// tables, so the store cannot fault on a lazily backed buffer either. See
    /// `UserMemory.materializeRange`.
    ///
    /// The buffer is not cleared first: neither record has a hole in it, so one
    /// store of a fully initialised value writes every byte of the `size` this
    /// validated, and nothing past it.
    private static func userRecord(
        at address: UInt64,
        size      : Int
    ) -> UnsafeMutableRawPointer? {

        guard address & 7 == 0 else { return nil }

        guard UserMemory.validateRegion(
            addr       : address,
            size       : size,
            permissions: [.write, .user]
        ) else { return nil }

        return UnsafeMutableRawPointer(bitPattern: UInt(address))
    }
}
