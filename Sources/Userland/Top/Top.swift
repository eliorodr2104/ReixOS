//
//  Top.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.

import Reix

/// Bounded consumer over the profiler's SHM export: page 0 is a seqlock'd
/// snapshot of `SystemStats` plus a `ProcessStats` table, pages 1-3 are one
/// ring of fixed-size event records. Neither layout is a shared Swift type
/// because the ring's record format is a wire contract with the kernel's
/// internal `TraceEvent`, which userland cannot import.
private enum Export {
    static let pageSize     = 4096
    static let ringPages    = 3

    /// Matches the kernel's own `TraceExport.processLimit`: page 0 has room
    /// for exactly this many `ProcessStats` slots.
    static let maxProcesses = 16
}

/// Reads the stats page (page 0) under the kernel's seqlock: even `seq`
/// means stable, odd means a writer is mid-update, and a `seq` that changed
/// between the two reads means the data was torn. Both cases just retry.
private struct StatsPage {
    let base: UnsafeRawPointer

    /// Copies the current `SystemStats` and up to `buffer.count`
    /// `ProcessStats` entries into place. Returns how many were copied.
    func read(
        sys   : inout SystemStats,
        buffer: UnsafeMutableBufferPointer<ProcessStats>
    ) -> Int {

        while true {
            let before = base.load(fromByteOffset: 0, as: UInt32.self)
            if before & 1 != 0 { continue }

            sys = base.load(fromByteOffset: 8, as: SystemStats.self)

            let processCount = base.load(fromByteOffset: 56, as: UInt32.self)
            let toRead       = min(Int(processCount), buffer.count)

            for i in 0..<toRead {
                buffer[i] = base.load(fromByteOffset: 64 + i * 48, as: ProcessStats.self)
            }

            let after = base.load(fromByteOffset: 0, as: UInt32.self)
            if after == before { return toRead }
        }
    }
}

/// The event ring spanning pages 1-3: `tail` (producer, monotonic) and
/// `head` (consumer, monotonic, ours to advance) are cursors masked only at
/// the point of indexing, exactly like the kernel's own `TraceRing`.
private struct EventRing {
    static let dataOffset  = 16
    static let recordBytes = 32

    let base: UnsafeMutableRawPointer
    let mask: UInt32

    var tail: UInt32 { base.load(fromByteOffset: 0, as: UInt32.self) }

    var head: UInt32 {
        get { base.load(fromByteOffset: 4, as: UInt32.self) }
        nonmutating set {
            base.storeBytes(of: newValue, toByteOffset: 4, as: UInt32.self)
        }
    }

    var dropped: UInt64 { base.load(fromByteOffset: 8, as: UInt64.self) }

    /// Drains every record between our last-seen head and the producer's
    /// tail, then publishes the new head. Returns how many were drained.
    ///
    /// Fields are read but not surfaced: nothing Top prints needs them yet,
    /// this just proves out the wire format record by record.
    func drain() -> Int {
        let currentTail = tail

        // Acquire: orders the record reads after this tail load.
        dmbISH()

        var cursor = head
        var count  = 0

        while cursor != currentTail {
            let offset = Self.dataOffset + Int(cursor & mask) * Self.recordBytes

            _ = base.load(fromByteOffset: offset,      as: UInt64.self) // timestamp
            _ = base.load(fromByteOffset: offset + 8,  as: UInt16.self) // code
            _ = base.load(fromByteOffset: offset + 10, as: UInt16.self) // info
            _ = base.load(fromByteOffset: offset + 12, as: UInt32.self) // pid
            _ = base.load(fromByteOffset: offset + 16, as: UInt64.self) // a
            _ = base.load(fromByteOffset: offset + 24, as: UInt64.self) // b

            cursor &+= 1
            count   += 1
        }

        // Release: publish head only once every record has been read.
        dmbISH()
        head = cursor

        return count
    }
}

/// Largest power of two that is `<= n`. Mirrors `Ring.init`'s own sizing
/// loop so the two ring flavors agree on how capacity is derived.
private func largestPowerOfTwo(lessOrEqual n: Int) -> Int {
    var size = 1
    while size * 2 <= n { size *= 2 }
    return size
}

private extension ProcessStatusCode {

    var label: StaticString {

        switch self {
            case .new             : "New"
            case .ready           : "Ready"
            case .running         : "Running"
            case .waiting         : "Waiting"
            case .blockedOnSend   : "Blocked on Send"
            case .blockedOnReceive: "Blocked on Receive"
            case .blockedOnReply  : "Blocked on Reply"
            case .terminated      : "Terminated"
        }

    }
}

/// Emits `stats.name`'s first `nameLength` bytes, left-aligned to `width`,
/// capped at the field's own 16-byte storage width.
private func printName(
    _ stats: ProcessStats,
      width: Int
) {
    let length = min(Int(stats.nameLength), 16)

    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 16) { buffer in
        for i in 0..<length {
            buffer[i] = stats.name[i]
        }
        printPadded(buffer.baseAddress!, count: length, width: width)
    }
}

@_cdecl("_start")
public func main() {

    _ = Runtime.bootstrap()

    print("")
    print("[ TOP   ] Hi, this is top process!\n")

    sleep(for: .seconds(5))

    let shm = shmCreate(pageCount: UInt64(1 + Export.ringPages))

    guard shm.isValid, profileAttachExport(handle: shm.handle) else {
        print("[ TOP   ] attach failed")

        while true { sleep(for: .seconds(1)) }
    }

    let shmBase = UnsafeMutableRawPointer(bitPattern: UInt(shm.address))!

    let statsPage = StatsPage(base: UnsafeRawPointer(shmBase))

    let ringBytes    = Export.ringPages * Export.pageSize
    let ringCapacity = largestPowerOfTwo(
        lessOrEqual: (ringBytes - EventRing.dataOffset) / EventRing.recordBytes
    )
    let ring = EventRing(
        base: shmBase + Export.pageSize,
        mask: UInt32(ringCapacity - 1)
    )

    var sys = SystemStats()
    

    var isNewScan = false
    withUnsafeTemporaryAllocation(
        of      : ProcessStats.self,
        capacity: Export.maxProcesses
    ) { buffer in

        while true {
            sleep(for: .seconds(1))

            let processCount = statsPage.read(sys: &sys, buffer: buffer)
            let drained      = ring.drain()

            print("")
            if isNewScan {
                print("")
                print("=========================== NEW SCAN ===========================")
                print("")
            }
            
            print("[ TOP   ]  PID  NAME                CPU_US  PAGES     MEM     STATUS")

            let microsPerTick = sys.counterFreq / 1_000_000

            for i in 0..<processCount {
                let stats     = buffer[i]
                let cpuMicros = microsPerTick > 0 ? stats.cpuTime / microsPerTick : 0

                print("[ TOP   ] ", terminator: "")
                printDecPadded(stats.pid, width: 4)
                print("  ", terminator: "")
                printName(stats, width: 16)
                print(" ", terminator: "")
                printDecPadded(cpuMicros, width: 9)
                print("  ", terminator: "")
                printDecPadded(UInt64(stats.residentPages), width: 4)
                print("  ", terminator: "")
                
                let memoryNormalized = normalizeRam(pages: UInt64(stats.residentPages))
                
                printDecPadded(UInt64(memoryNormalized.value), width: 3)
                print(" ", terminator: "")
                print(memoryNormalized.unit, terminator: "")
                print("     ", terminator: "")
                print(ProcessStatusCode(rawValue: stats.status)?.label ?? "Nil")
            }

            print("\n")
            print("===========================  PAGES   ========================")
            print("")
            
            print("[ TOP   ] FREE PAGES      EVENTS   DROPPED   MEM FREE")
            print("[ TOP   ]", terminator: " ")
            printDec(sys.freePages, terminator: "")
            print("/", terminator: "")
            printDec(sys.totalPages, terminator: "")
            
            printDecPadded(UInt64(drained), width: 11)
            printDecPadded(ring.dropped, width: 10)
            
            let normalizedRam = normalizeRam(pages: sys.freePages)
            
            printDecPadded(normalizedRam.value, width: 9)
            print(" ", terminator: "")
            print(normalizedRam.unit)
            
            isNewScan = true
        }
    }

    print("[ TOP   ] done")

    while true {
        sleep(for: .seconds(1))
    }
}

private func normalizeRam(pages: UInt64) -> (value: UInt64, unit: StaticString) {
   
    let memoryBytes = pages * UInt64(4096)
    
    guard memoryBytes > 0 else { return (0, "B") }
    
    if memoryBytes >= 0x10000000000 {
        return (memoryBytes >> 40, "TiB")
    }
    
    if memoryBytes >= 0x40000000 {
        return (memoryBytes >> 30, "GiB")
    }
    
    if memoryBytes >= 0x100000 {
        return (memoryBytes >> 20, "MiB")
    }
    
    if memoryBytes >= 0x400 {
        return (memoryBytes >> 10, "KiB")
    }
    
    return (memoryBytes, "B")
}
