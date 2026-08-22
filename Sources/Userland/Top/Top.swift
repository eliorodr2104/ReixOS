//
//  Top.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.

import Reix

/// How many times the table is redrawn before the tool ends.
///
/// Bounded on purpose: without a way to interrupt a running program, a `top`
/// that never returns is a `top` that takes the terminal with it.
private enum Top {
    static let refreshes = 3
}

@_cdecl("_start")
public func main() {

    let environment = Runtime.bootstrap()

    print("")
    print("[ TOP   ] Hi, this is top process!\n")

    sleep(for: .seconds(5))

    guard let profiler = environment.profiler else {
        print("[ TOP   ] profiler authority missing")
        exit(code: 1)
    }

    let shm = shmCreate(pageCount: UInt64(1 + Export.ringPages))

    guard shm.isValid, profileAttachExport(handle: shm.handle, authority: profiler) else {
        print("[ TOP   ] attach failed")
        exit(code: 1)
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

        for _ in 0..<Top.refreshes {
            sleep(for: .seconds(1))

            let processCount = statsPage.read(sys: &sys, buffer: buffer)
            let drained      = ring.drain()

            print("")
            if isNewScan {
                print("")
                print("=========================== NEW SCAN ===========================")
                print("")
            }
            
            print("[ TOP   ]  PID  NAME                CPU_US  PAGES  STACK     MEM     STATUS")

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
                printDecPadded(UInt64(stats.stackPages), width: 5)
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
    exit(code: 0)
}

/// Largest power of two that is `<= n`. Mirrors `Ring.init`'s own sizing
/// loop so the two ring flavors agree on how capacity is derived.
private func largestPowerOfTwo(lessOrEqual n: Int) -> Int {
    var size = 1
    while size * 2 <= n { size *= 2 }
    return size
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
