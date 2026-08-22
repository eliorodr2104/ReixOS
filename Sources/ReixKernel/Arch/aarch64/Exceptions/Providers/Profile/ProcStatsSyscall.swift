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
/// `x0` = the sub-operation, `x1` = its cursor, `x2` = a 48-byte user buffer,
/// `x3` = the profiler capability handle. Sub-operation 0 fills a `SystemStats`
/// and answers `0`; sub-operation 1 fills a `ProcessStats` and answers the pid
/// it described. `UInt64.max` is the only failure value, and also the end of the
/// process sweep: a caller walking the table has one thing to test either way.
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
    ///
    /// `freePages` is derived here rather than counted in the allocator, see
    /// `PhysicalPageManager.allocatedPages`. The idle time is the scheduler's
    /// closed stretches only, which loses nothing: the caller is running, so the
    /// machine is by definition not idle at the moment it asks.
    private static func reportSystem(
        into buffer: UInt64,
        context    : SyscallContext
    ) -> UInt64 {

        guard let record = userRecord(
            at  : buffer,
            size: MemoryLayout<SystemStats>.size
        ) else { return UInt64.max }

        let total     = context.ppm.pointee.totalPages
        let allocated = context.ppm.pointee.allocatedPages

        var stats = SystemStats()

        stats.totalPages  = total
        stats.freePages   = allocated >= total ? 0 : total - allocated
        stats.systemTicks = context.scheduler.pointee.systemTicks
        stats.idleTime    = context.scheduler.pointee.idleTime
        stats.counterFreq = Arch.Timer.frequency()
        stats.traceLost   = TraceRing.lost

        stats.kernelStackPeak    = UInt32(StackUsage.kernelStack)
        stats.exceptionStackPeak = UInt32(StackUsage.exceptionStack)

        record.assumingMemoryBound(to: SystemStats.self).pointee = stats

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

        record.assumingMemoryBound(to: ProcessStats.self).pointee = snapshot(of: process)

        return process.pointee.pid
    }


    /// One process, as the ABI reports it.
    ///
    /// The running process is charged its open slice here, so a reader sampling
    /// twice sees time move for whoever is on the CPU instead of a value frozen
    /// until the next rotation.
    ///
    /// `scheduledAt` is reported for that one process only. A process taken off
    /// the CPU has it cleared by the rotation that charged its slice, but one
    /// killed while running is never rotated off, and a stale reading on a
    /// corpse would read as a slice still open.
    private static func snapshot(
        of process: UnsafeMutablePointer<Process>
    ) -> ProcessStats {

        var stats = ProcessStats()

        var isRunning   = false
        var scheduledAt = process.pointee.scheduledAt

        if case .running = process.pointee.status, scheduledAt != 0 {
            isRunning = true

        } else { scheduledAt = 0 }

        var cpuTime = process.pointee.cpuTime
        if isRunning {
            cpuTime &+= Arch.Timer.counter() &- scheduledAt
        }

        stats.pid         = process.pointee.pid
        stats.cpuTime     = cpuTime
        stats.status      = statusCode(of: process.pointee.status)
        stats.scheduledAt = scheduledAt

        stats.residentPages = process.pointee.addressSpace.vmaManager?.pointee.residentPages ?? 0

        let stackPages = process.pointee.addressSpace.vmaManager?.pointee.stackPages ?? 0
        stats.stackPages = UInt16(min(stackPages, UInt32(UInt16.max)))

        if let metadata = process.pointee.metadata {
            stats.nameLength = metadata.pointee.nameLength

            for index in 0..<stats.name.count {
                stats.name[index] = metadata.pointee.name[index]
            }
        }

        return stats
    }


    /// The scheduler state, mapped into the ABI's `ProcessStatusCode`.
    ///
    /// Written out rather than derived from a `RawRepresentable` conformance on
    /// `ProcessStatus`: two of its cases carry an endpoint pointer, so the enum
    /// cannot have a raw value.
    private static func statusCode(of status: ProcessStatus) -> UInt8 {
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
    /// The buffer is not cleared first: both records are packed with no hole in
    /// them, so one store of a fully initialised value writes every byte.
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
