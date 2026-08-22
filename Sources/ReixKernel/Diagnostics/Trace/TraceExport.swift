//
//  TraceExport.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

import ReixABI

struct TraceExportBatch {
    static let tailOffset    = 0
    static let recordsOffset = 16
    static let recordSize    = 32

    private let ring   : UnsafeMutableRawPointer
    private let mask   : UInt32
    private var pending: UInt32 = 0

    private(set) var producer: UInt32

    init(
        ring    : UnsafeMutableRawPointer,
        producer: UInt32,
        mask    : UInt32
    ) {
        self.ring     = ring
        self.producer = producer
        self.mask     = mask
    }

    mutating func append(_ event: TraceEvent) {
        let offset = Self.recordsOffset + Int(producer & mask) * Self.recordSize

        ring.storeBytes(of: event.timestamp, toByteOffset: offset,      as: UInt64.self)
        ring.storeBytes(of: event.code,      toByteOffset: offset +  8, as: UInt16.self)
        ring.storeBytes(of: event.info,      toByteOffset: offset + 10, as: UInt16.self)
        ring.storeBytes(of: event.pid,       toByteOffset: offset + 12, as: UInt32.self)
        ring.storeBytes(of: event.a,         toByteOffset: offset + 16, as: UInt64.self)
        ring.storeBytes(of: event.b,         toByteOffset: offset + 24, as: UInt64.self)

        producer &+= 1
        pending  &+= 1
    }

    mutating func publish() {
        guard pending != 0 else { return }

        Arch.MMU.pageTableBarrier()
        ring.storeBytes(of: producer, toByteOffset: Self.tailOffset, as: UInt32.self)
        pending = 0
    }
}

/// The live half of the profiler: kernel state published into a page the
/// consumer owns, refreshed from the timer tick.
///
/// `TraceDump` answers "what just happened" once, through the console, at the
/// cost of a syscall and a few thousand UART bytes. That is the wrong shape for
/// a `top`: a reader that wants the machine every tenth of a second cannot pay
/// a dump for each look, and the console is not a channel it can parse without
/// also parsing everything else on it. So the kernel writes instead, into
/// memory userland allocated with `shmCreate` and handed over with
/// `profileControl(.attachExport, handle)`, and the reader polls it.
///
/// ## The region
///
/// Page 0 is a stats snapshot behind a seqlock:
///
///     @0   seq          UInt32   odd while being written
///     @4   reserved     UInt32
///     @8   SystemStats  56 B
///     @64  processCount UInt32
///     @68  reserved     UInt32
///     @72  ProcessStats 48 B each, up to 16
///
/// Pages 1 and up are an event ring:
///
///     @0   tail    UInt32   producer, monotonic, the kernel's
///     @4   head    UInt32   consumer, monotonic, the reader's
///     @8   dropped UInt64
///     @16  records 32 B each, `capacity` of them
///
/// `capacity` is the largest power of two that fits, so the producer masks
/// rather than divides. Both cursors are monotonic and only ever masked at the
/// point of access, which is `TraceRing`'s idiom and for its reason: `tail &-
/// head` is the fill level and needs no empty-versus-full flag.
///
/// The kernel never overwrites a record the reader has not taken. A profiler
/// that silently replaced live data would make every measurement conditional on
/// the reader having kept up; here a full ring simply stops being filled, the
/// records wait their turn in `TraceRing`, and `dropped` counts only what was
/// evicted there and can never be delivered. The reader is therefore always
/// told exactly how much of the stream it is missing.
///
/// ## Lifetime
///
/// The exporter retains the backing independently of the caller's capability
/// and releases it on detach, replacement, or owner teardown.
enum TraceExport {

    // MARK: - Wire layout

    /// Byte offsets inside page 0. Wire constants: the userland consumer
    /// hardcodes the same numbers, so add fields, never move one.
    private static let seqOffset          = 0
    private static let systemStatsOffset  = 8
    private static let processCountOffset = 64
    private static let processStatsOffset = 72

    /// `ProcessStats` on the wire, and how many of them page 0 has room for.
    /// The stride is the ABI struct's own, restated here because the offsets
    /// above are a contract and not a consequence of a Swift layout.
    private static let processStatsStride = 48
    private static let processLimit       = 16

    /// Byte offsets inside the ring header, which starts at page 1.
    private static let ringTailOffset    = TraceExportBatch.tailOffset
    private static let ringHeadOffset    = 4
    private static let ringDroppedOffset = 8
    private static let ringRecordsOffset = TraceExportBatch.recordsOffset

    /// One `TraceEvent` on the wire: the six fields of the struct at their
    /// natural offsets, no padding and no hole.
    private static let recordSize = TraceExportBatch.recordSize


    // MARK: - Budget

    /// Records moved per tick while `TraceRing` is close to empty.
    ///
    /// Sixteen is 1,600 events per second sustained at the 100 Hz tick rate,
    /// which is what an idle-to-normal kernel needs and costs a quiet system
    /// only 96 stores a tick for it.
    private static let baseEventBudget = 16

    /// Records moved per tick once `TraceRing` is filling up faster than
    /// `baseEventBudget` drains it.
    ///
    /// A quarter of `TraceRing.capacity` (256): a backlog that reaches the
    /// whole ring drains in at most four ticks instead of thirty-two, while a
    /// single tick still never copies more than 64 * 32 = 2,048 bytes, a few
    /// hundred stores that cannot meaningfully delay the scheduler, sleep
    /// wakeups, or IPC timeouts riding the same tick. The overflow is not
    /// lost either way: whatever a tick leaves behind, the next one takes,
    /// and only a producer that outruns the catch-up rate for longer than the
    /// ring is deep loses anything at all.
    private static let catchUpEventBudget = 64

    /// Ticks between stats refreshes. At 10 ms per tick this is three
    /// refreshes a second, which is faster than anybody reads a `top` and slow
    /// enough that the process walk is invisible against the tick it rides.
    private static let statsPeriod: UInt64 = 32


    // MARK: - State

    /// Page 0 of the attached region, `nil` until somebody attaches.
    ///
    /// Every entry point loads this first and returns on `nil`, so a kernel
    /// nobody is watching pays one load and one branch per tick and nothing
    /// else. The pointer is into the linear map, so it stays valid whatever
    /// address space is installed.
    private static var region: UnsafeMutableRawPointer? = nil

    /// The process whose capability names the attached region, `0` when nobody
    /// is attached. No process is ever numbered zero, so a pid can never match
    /// an unattached exporter.
    private static var owner: PID = 0
    private static var backing: UnsafeMutablePointer<SharedRegion>? = nil

    private static var ringCapacity: UInt32 = 0
    private static var ringMask    : UInt32 = 0

    private static var scheduler     : UnsafeMutablePointer<KernelScheduler>? = nil
    private static var ppm           : UnsafeMutablePointer<KernelPPM>?       = nil
    private static var heap          : UnsafeMutablePointer<KernelHeap>?      = nil
    private static var processManager: UnsafeMutablePointer<ProcessManager>?  = nil

    /// The producer cursor, mirrored here so publishing does not have to read
    /// back a word the consumer is allowed to be reading.
    private static var producer: UInt32 = 0

    /// Records the reader will never see: the ones `TraceRing` evicted before
    /// the export cursor reached them.
    private static var dropped: UInt64 = 0

    /// Where the last drain left off in `TraceRing`.
    private static var exportCursor: UInt32 = 0

    /// Ticks since attach, against `statsPeriod`.
    private static var ticks: UInt64 = 0

    /// Seqlock generation. Even means page 0 is readable.
    private static var sequence: UInt32 = 0


    // MARK: - Attach

    /// Retains `backing` as the export region and starts publishing through `base`.
    ///
    /// `base` is the kernel's linear-map window on the region's frames and
    /// `pageCount` its length, both already validated by the caller against
    /// the capability that named it. The scheduler and the PPM come from the
    /// syscall context rather than from `Kernel`, so the tick reads exactly the
    /// instances the syscall layer was built with.
    ///
    /// A second attach replaces the first without ceremony. There is one
    /// consumer, and a kernel that refused would leave a process that died
    /// mid-run holding the exporter for the rest of the uptime.
    ///
    /// The owner recorded is whoever is running, which on this path is the
    /// caller of `profileControl(.attachExport, handle)`.
    ///
    /// Page 0 is cleared here so every reserved word and every process slot
    /// past `processCount` reads as zero rather than as whatever the frame was
    /// last used for. The export cursor starts at "now": see
    /// `TraceRing.currentHead`.
    static func attach(
        base          : UnsafeMutableRawPointer,
        backing       : UnsafeMutablePointer<SharedRegion>,
        pageCount     : UInt32,
        scheduler     : UnsafeMutablePointer<KernelScheduler>,
        ppm           : UnsafeMutablePointer<KernelPPM>,
        heap          : UnsafeMutablePointer<KernelHeap>,
        processManager: UnsafeMutablePointer<ProcessManager>
    ) -> Bool {
        guard pageCount >= 2 else { return false }

        let pageSize  = Int(UserSpaceLayout.pageSize)
        let ringBytes = Int(pageCount - 1) * pageSize

        guard let capacity = largestPowerOfTwo(
            atMost: (ringBytes - ringRecordsOffset) / recordSize
        ) else { return false }

        retainSharedRegion(backing)
        detachCurrent()

        let ring = base + pageSize

        clear(base, bytes: pageSize)

        ring.storeBytes(of: UInt32(0), toByteOffset: ringTailOffset,    as: UInt32.self)
        ring.storeBytes(of: UInt32(0), toByteOffset: ringHeadOffset,    as: UInt32.self)
        ring.storeBytes(of: UInt64(0), toByteOffset: ringDroppedOffset, as: UInt64.self)

        Self.ringCapacity   = capacity
        Self.ringMask       = capacity &- 1
        Self.scheduler      = scheduler
        Self.ppm            = ppm
        Self.heap           = heap
        Self.processManager = processManager

        Self.producer     = 0
        Self.dropped      = 0
        Self.ticks        = 0
        Self.sequence     = 0
        Self.exportCursor = TraceRing.currentHead

        Self.owner   = Arch.CPU.getCurrentProcess()?.pointee.pid ?? 0
        Self.backing = backing

        // One refresh now, so a reader that polls immediately finds an even
        // `seq` and real numbers instead of a page of zeroes for 320 ms.
        refreshStats(into: base)
        Self.region = base

        return true
    }


    // MARK: - Detach

    /// Stops publishing if `pid` is the process that attached the region.
    ///
    /// Every process teardown calls this, unconditionally: the pid test is the
    /// whole guard, so no teardown path has to know whether anybody is watching.
    /// It runs before the address-space and capability teardown so the exporter
    /// releases its ownership before those paths release theirs.
    ///
    /// `region` is cleared first because it is what every entry point gates on,
    /// so a tick can only ever see the exporter attached or wholly gone. Every
    /// cursor goes back to its initial value too: a later attach installs a
    /// fresh region whose header reads zero, and a producer left at the old
    /// region's progress would name a slot the new reader has not been given.
    static func detach(pid: PID) {
        guard pid == owner, region != nil else { return }

        detachCurrent()
    }

    private static func detachCurrent() {
        let releasedBacking = backing
        let releasedPPM     = ppm
        let releasedHeap    = heap

        region = nil
        backing = nil
        owner  = 0

        ringCapacity = 0
        ringMask     = 0

        scheduler      = nil
        ppm            = nil
        heap           = nil
        processManager = nil

        producer     = 0
        dropped      = 0
        ticks        = 0
        sequence     = 0
        exportCursor = 0

        if let releasedBacking, let releasedPPM, let releasedHeap {
            _ = releaseSharedRegion(
                releasedBacking,
                ppm : releasedPPM,
                heap: releasedHeap
            )
        }
    }


    /// The largest power of two at most `value`, or `nil` when `value` is less
    /// than one and the region has no room for a single record.
    private static func largestPowerOfTwo(atMost value: Int) -> UInt32? {
        guard value >= 1 else { return nil }

        let limit  = UInt32(truncatingIfNeeded: value)
        var result = UInt32(1)

        while result <= limit / 2 { result <<= 1 }

        return result
    }


    /// Zeroes `bytes` from `base`, eight at a time. One-time work on the
    /// attach path, so there is nothing to gain from anything cleverer.
    private static func clear(_ base: UnsafeMutableRawPointer, bytes: Int) {
        var offset = 0

        while offset < bytes {
            base.storeBytes(of: UInt64(0), toByteOffset: offset, as: UInt64.self)
            offset &+= 8
        }
    }


    // MARK: - Tick path

    /// The tick's whole export obligation.
    ///
    /// Called once per timer tick, as the handler's last piece of side work.
    /// Nothing happens until somebody attaches: the load in the first line is
    /// the entire cost of an unattached kernel.
    ///
    /// ## Budget
    ///
    /// Worst case for an ordinary tick: `catchUpEventBudget` (64) records of
    /// six stores each, one `dsb ishst`, one cursor store, and one read of the
    /// consumer's head — bounded regardless of how far behind the kernel ring
    /// has fallen, since the budget never exceeds that constant. One tick in
    /// 32 adds a stats refresh, which is one 48-byte store for the system
    /// counters and, for at most sixteen processes, a 48-byte store and a
    /// 16-byte name copy each. Every figure it reports is a counter somebody
    /// else already maintains, so there is no walk inside the walk: a few
    /// kilobytes of stores at the worst is the whole of the interrupt latency
    /// this subsystem adds.
    ///
    /// - Note: IRQs are masked for the length of the tick handler, so no emit
    ///   can reach `TraceRing` while the drain below reads it. That is the
    ///   invariant `TraceRing` states, and the reason no cursor here is atomic.
    @inline(never)
    static func pump() {
        guard let base = region else { return }

        ticks &+= 1

        drainEvents(into: base + Int(UserSpaceLayout.pageSize))

        guard ticks % statsPeriod == 0 else { return }

        refreshStats(into: base)
    }


    // MARK: - Event ring

    /// Moves as many records as the shared ring has room for, up to an
    /// occupancy-driven budget, and reports whatever the kernel ring evicted
    /// meanwhile.
    ///
    /// The free-slot count is what bounds the copy, so the body below cannot
    /// overrun a reader that has fallen behind: a record with nowhere to go is
    /// left in `TraceRing`, which holds 256 of them and is the buffer that
    /// absorbs a consumer's bad second. Only when the kernel ring evicts one
    /// before the cursor reaches it does anything become unrecoverable, and
    /// that is exactly what `drainForExport` returns.
    ///
    /// `occupancy` is how far `TraceRing`'s writer has gotten ahead of
    /// `exportCursor`, the same quantity `drainForExport` computes internally
    /// to decide whether it must skip. Reading it here only chooses between
    /// `baseEventBudget` and `catchUpEventBudget`: a stale or even a wrapped
    /// value can never push the chosen budget past `catchUpEventBudget`, so
    /// it is a hint that sizes the drain and never a hazard that could size
    /// it unboundedly.
    ///
    /// The consumer's cursor is read once per tick rather than once per record:
    /// it only moves forward, so a stale read costs a record its place on this
    /// tick and nothing else.
    ///
    /// - Note: `head` is a word user space can write anything into, so nothing
    ///   here may derive a length or an address from it. The subtraction is
    ///   clamped and the slot index is masked, both of which stay in range for
    ///   every value the consumer could put there.
    private static func drainEvents(into ring: UnsafeMutableRawPointer) {
        let consumer = ring.load(fromByteOffset: ringHeadOffset, as: UInt32.self)
        let used     = producer &- consumer
        let free     = used >= ringCapacity ? 0 : Int(ringCapacity &- used)

        let occupancy = TraceRing.currentHead &- exportCursor
        let want      = occupancy > UInt32(baseEventBudget) ? catchUpEventBudget : baseEventBudget
        let budget    = free < want ? free : want

        var batch = TraceExportBatch(ring: ring, producer: producer, mask: ringMask)

        // Called even with a budget of zero: a reader that is not keeping up
        // still has to be told how much of the stream it has lost.
        let evicted = TraceRing.drainForExport(
            from: &exportCursor,
            max : budget
        ) { event in
            batch.append(event)
        }

        if evicted != 0 {
            dropped &+= UInt64(evicted)
            ring.storeBytes(of: dropped, toByteOffset: ringDroppedOffset, as: UInt64.self)
        }

        batch.publish()
        producer = batch.producer
    }


    /// The store barrier that publishes data before the cursor naming it.
    ///
    /// `dsb ishst`, borrowed from the page-table path: inner-shareable and
    /// store-only, which is exactly the ordering a single-producer ring needs,
    /// and stronger than the `dmb ish` the protocol asks for. It is also the
    /// only data barrier the kernel image links, the generated `dmb_ish` being
    /// rendered into the userland object set alone.
    @inline(__always)
    private static func publishBarrier() {
        Arch.MMU.pageTableBarrier()
    }


    // MARK: - Stats page

    /// Rewrites page 0 under the seqlock.
    ///
    /// `seq` goes odd before the first store and even after the last, and the
    /// reader retries whenever it finds an odd value or sees the word move
    /// under it. A seqlock and not a lock because the writer is a timer
    /// interrupt and must never wait on a user process, and because the only
    /// cost of losing the race is the reader looking again.
    ///
    /// Every scheduler and PPM scalar is read into a local before the process
    /// walk starts. Reading one inside `forEachProcess` would be a second
    /// access to a value the walk is already reading, which is an exclusivity
    /// violation and not merely untidy.
    ///
    /// The counters are the same ones `ProcStatsSyscall` reports, read the same
    /// way. The two providers deliberately share no code: that one answers a
    /// caller's own buffer under `validateRegion` and this one writes a region
    /// the kernel already owns, and the only thing they have in common is the
    /// arithmetic, which is a subtraction.
    private static func refreshStats(into page: UnsafeMutableRawPointer) {
        guard let scheduler      = Self.scheduler,
              let ppm            = Self.ppm,
              let processManager = Self.processManager
        else { return }

        let now       = Arch.Timer.counterUnordered()
        let total     = ppm.pointee.totalPages
        let allocated = ppm.pointee.allocatedPages

        var stats = SystemStats()

        stats.totalPages  = total
        stats.freePages   = allocated >= total ? 0 : total - allocated
        stats.systemTicks = scheduler.pointee.systemTicks
        stats.idleTime    = scheduler.pointee.idleTime
        stats.counterFreq = Arch.Timer.frequency()
        stats.traceLost   = TraceRing.lost

        stats.kernelStackPeak    = UInt32(StackUsage.kernelStack)
        stats.exceptionStackPeak = UInt32(StackUsage.exceptionStack)

        sequence &+= 1
        page.storeBytes(of: sequence, toByteOffset: seqOffset, as: UInt32.self)
        publishBarrier()

        let systemSlot = page + systemStatsOffset
        systemSlot.assumingMemoryBound(to: SystemStats.self).pointee = stats
        var slotIndex: UInt32 = 0

        // The family tree, not the scheduler queues: those miss every process
        // blocked on an endpoint, which is where the servers live.
        let visited = processManager.pointee.forEachProcess(upTo: UInt32(processLimit)) { process in
            let slot = page + processStatsOffset + Int(slotIndex) * processStatsStride
            slot.assumingMemoryBound(to: ProcessStats.self).pointee = snapshot(
                of : process,
                now: now
            )
            slotIndex &+= 1
        }

        page.storeBytes(of: visited, toByteOffset: processCountOffset, as: UInt32.self)

        publishBarrier()
        sequence &+= 1
        page.storeBytes(of: sequence, toByteOffset: seqOffset, as: UInt32.self)
    }


    /// One process, as the ABI reports it.
    ///
    /// The running process is the only one with an open slice, so its live
    /// `cpuTime` is the closed total plus `now - scheduledAt`. One `now` serves
    /// the whole refresh, and it is the unordered counter read: this is a
    /// report and not a measured region, so there is nothing an `isb` would
    /// keep on the right side of it.
    ///
    /// A corpse the parent has not reaped has already lost its metadata and its
    /// address space, so both are read through an optional and a missing one
    /// costs the slot its name or its page count, never the walk.
    private static func snapshot(
        of process: UnsafeMutablePointer<Process>,
        now       : UInt64
    ) -> ProcessStats {

        var stats = ProcessStats()

        let scheduledAt = process.pointee.scheduledAt

        var cpuTime = process.pointee.cpuTime
        if case .running = process.pointee.status, scheduledAt != 0 {
            cpuTime &+= now &- scheduledAt
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


    /// The scheduler state, as the wire numbers the ABI documents.
    ///
    /// Fixed by the ABI and not by `ProcessStatus`'s declaration order, so a
    /// case added to that enum leaves these alone. The two blocked-on-endpoint
    /// cases drop their endpoint: a reader has no way to name one.
    private static func statusCode(of status: ProcessStatus) -> UInt8 {
        switch status {
            case .new                : 0
            case .ready              : 1
            case .running            : 2
            case .waiting            : 3
            case .blockedOnSend(_)   : 4
            case .blockedOnReceive(_): 5
            case .blockedOnReply     : 6
            case .terminated         : 7
        }
    }
}
