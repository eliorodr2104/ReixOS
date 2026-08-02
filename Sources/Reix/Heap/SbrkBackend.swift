//
//  SbrkBackend.swift
//  ReixOS
//
//  Created by Eliomar on 21/06/2026.
//

import ReixABI


typealias UserArena = SbrkBackend<64>

/// `sbrk` arena, carved into 4 KiB pages, at most `arenaPages` of them.
///
/// The page count is a value generic rather than a `static let` because the
/// three bookkeeping arrays are all indexed by page number and must stay the
/// same length: a generic parameter makes that agreement structural instead of
/// three literals that have to be edited together. Value generics are also the
/// only way to drive an `InlineArray` length from a name at all: a `static let`
/// is rejected there.
///
/// Keep it at or below 65536: `freePages` holds page indices as `UInt16`.
struct SbrkBackend<let arenaPages: Int>: SlabBackend {

    var shifts    : InlineArray = InlineArray<arenaPages, UInt8 >(repeating: 0)
    var freeCounts: InlineArray = InlineArray<arenaPages, UInt16>(repeating: 0)

    /// Page indices, not addresses: the arena is contiguous from `arenaBase`, so
    /// a full pointer per slot was re-storing `arenaBase` in every entry at four
    /// times the cost, and an index cannot name a page outside the arena.
    var freePages : InlineArray = InlineArray<arenaPages, UInt16>(repeating: 0)

    var arenaBase: UInt         = 0
    var arenaEnd : UInt         = 0
    var freeTop  : UInt         = 0
    var started  : Bool         = false
    
    
    @inline(__always)
    private mutating func ensureStarted() {
        if started { return }
        
        arenaBase = UInt(brk(0))
        arenaEnd  = arenaBase
        started   = true
    }

    mutating func acquirePage() -> UnsafeMutableRawPointer? {
        ensureStarted()
        
        if freeTop > 0 {
            freeTop -= 1
            let index = UInt(freePages[Int(freeTop)])

            return UnsafeMutableRawPointer(bitPattern: arenaBase + (index << 12))
        }

        // Tested before growing: `sbrk` first leaves the break past the arena, and
        // a page there passes `UserHeap.free`'s range test with an unholdable index.
        guard (arenaEnd - arenaBase) >> 12 < UInt(arenaPages) else { return nil }

        let prev = sbrk(4096)
        if prev == RXMemoryError.memoryFailure { return nil }

        arenaEnd = UInt(brk(0))

        return UnsafeMutableRawPointer(bitPattern: UInt(prev))
    }

    mutating func releasePage(_ page: UnsafeMutableRawPointer) {
        _ = decommit(addr: UInt64(UInt(bitPattern: page)), size: 4096)

        // Unreachable from `SlabCore`, but the narrowing store below traps rather
        // than corrupts, and dropping an already-decommitted page leaks only its VA.
        let index = pageIndex(page)
        guard index < arenaPages, freeTop < UInt(arenaPages) else { return }

        freePages[Int(freeTop)] = UInt16(index)
        freeTop += 1
    }
    
    @inline(__always)
    mutating func bind(
        page : UnsafeMutableRawPointer,
        shift: UInt8
    ) {
        freeCounts[pageIndex(page)] = UInt16(4096 / (1 << Int(shift)) - 1)
        shifts    [pageIndex(page)] = shift
    }
    
    @inline(__always)
    func shift(ofPage page: UnsafeMutableRawPointer) -> UInt8 {
        shifts[pageIndex(page)]
    }

    @inline(__always)
    mutating func onAllocBlock(page: UnsafeMutableRawPointer) {
        if freeCounts[pageIndex(page)] > 0 { freeCounts[pageIndex(page)] -= 1 }
    }
    
    @inline(__always)
    mutating func onFreeBlock(page: UnsafeMutableRawPointer) -> Bool {
        freeCounts[pageIndex(page)] += 1
        
        return freeCounts[pageIndex(page)] >= UInt16(4096 / (1 << Int(shifts[pageIndex(page)])))
    }
    
    @inline(__always)
    private func pageIndex(_ page: UnsafeMutableRawPointer) -> Int {
        Int((UInt(bitPattern: page) - arenaBase) >> 12)
    }
}
