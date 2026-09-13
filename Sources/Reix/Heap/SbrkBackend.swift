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
/// four bookkeeping arrays are all indexed by page number and must stay the
/// same length: a generic parameter makes that agreement structural instead of
/// four literals that have to be edited together. Value generics are also the
/// only way to drive an `InlineArray` length from a name at all: a `static let`
/// is rejected there.
///
/// Keep it at or below 65536: `freePages` holds page indices as `UInt16`.
struct SbrkBackend<let arenaPages: Int>: SlabBackend {

    var shifts    : InlineArray = InlineArray<arenaPages, UInt8 >(repeating: 0)
    var freeCounts: InlineArray = InlineArray<arenaPages, UInt16>(repeating: 0)
    var liveBits  : InlineArray = InlineArray<arenaPages, UInt16>(repeating: 0)

    /// Page indices, not addresses: the arena is contiguous from `arenaBase`, so
    /// a full pointer per slot was re-storing `arenaBase` in every entry at four
    /// times the cost, and an index cannot name a page outside the arena.
    var freePages : InlineArray = InlineArray<arenaPages, UInt16>(repeating: 0)

    var arenaBase: UInt         = 0
    var arenaEnd : UInt         = 0
    var freeTop  : UInt         = 0
    var started  : Bool         = false
    
    
    @inline(__always)
    private mutating func ensureStarted() -> Bool {
        if started { return true }

        let initial = brk(0)
        guard initial != RXMemoryError.memoryFailure else { return false }

        let base = UInt(initial)
        guard base != 0, (base & UInt(0xFFF)) == 0 else { return false }

        arenaBase = base
        arenaEnd  = base
        started   = true
        return true
    }

    mutating func acquirePage() -> UnsafeMutableRawPointer? {
        guard ensureStarted() else { return nil }
        
        if freeTop > 0 {
            let nextTop = freeTop - 1
            let index = UInt(freePages[Int(nextTop)])
            guard index < UInt(arenaPages) else { return nil }

            let (address, overflow) = arenaBase.addingReportingOverflow(index << 12)
            guard !overflow else { return nil }

            freeTop = nextTop
            return UnsafeMutableRawPointer(bitPattern: address)
        }

        // Tested before growing: `sbrk` first leaves the break past the arena, and
        // a page there passes `UserHeap.free`'s range test with an unholdable index.
        guard arenaEnd >= arenaBase,
              (arenaEnd - arenaBase) >> 12 < UInt(arenaPages)
        else { return nil }

        // Reconcile the process break before changing it. Publishing `arenaEnd`
        // only after the direct growth result is exact makes each attempt one
        // bounded transaction even if a query returns malformed data.
        let observed = brk(0)
        guard observed != RXMemoryError.memoryFailure, UInt(observed) == arenaEnd else {
            return nil
        }

        let previousEnd = arenaEnd
        let (expectedEnd, overflow) = previousEnd.addingReportingOverflow(4096)
        guard !overflow else { return nil }

        let current = brk(UInt64(expectedEnd))
        guard current != RXMemoryError.memoryFailure, UInt(current) == expectedEnd else {
            return nil
        }
        arenaEnd = expectedEnd

        return UnsafeMutableRawPointer(bitPattern: previousEnd)
    }

    mutating func releasePage(_ page: UnsafeMutableRawPointer) {
        guard owns(page: page) else { return }
        let index = pageIndex(page)
        guard shifts[index] != 0, freeTop < UInt(arenaPages) else { return }

        _ = decommit(addr: UInt64(UInt(bitPattern: page)), size: 4096)

        // Decommit is opportunistic: even if the kernel retains the physical
        // backing, the empty virtual page stays ours and is safe to recycle.
        // Clear the old class and liveness before publishing its index again.
        shifts[index] = 0
        freeCounts[index] = 0
        liveBits[index] = 0

        freePages[Int(freeTop)] = UInt16(index)
        freeTop += 1
    }

    @inline(__always)
    func owns(page: UnsafeMutableRawPointer) -> Bool {
        guard started else { return false }

        let address = UInt(bitPattern: page)
        guard address >= arenaBase, address < arenaEnd else { return false }

        let offset = address - arenaBase
        return (offset & UInt(0xFFF)) == 0
            && (offset >> 12) < UInt(arenaPages)
    }
    
    @inline(__always)
    mutating func bind(
        page : UnsafeMutableRawPointer,
        shift: UInt8
    ) {
        let index = pageIndex(page)
        let blockCount = 4096 / (1 << Int(shift))
        let reserved = SlabCore<Self>.reservedBlockCount(forShift: shift)

        freeCounts[index] = UInt16(blockCount - reserved)
        liveBits[index] = 0
        shifts[index] = shift
    }
    
    @inline(__always)
    func shiftIfOwned(ofPage page: UnsafeMutableRawPointer) -> UInt8? {
        guard owns(page: page) else { return nil }
        let shift = shifts[pageIndex(page)]
        return shift == 0 ? nil : shift
    }

    @inline(__always)
    func isAllocatedBlock(
        page      : UnsafeMutableRawPointer,
        blockIndex: Int,
        shift     : UInt8
    ) -> Bool {
        if shift < 8 { return slabPageBitIsSet(page: page, blockIndex: blockIndex) }

        return (liveBits[pageIndex(page)] & (UInt16(1) << UInt16(blockIndex))) != 0
    }

    @inline(__always)
    mutating func onAllocBlock(
        page      : UnsafeMutableRawPointer,
        blockIndex: Int,
        shift     : UInt8
    ) -> Bool {
        let index = pageIndex(page)
        guard freeCounts[index] > 0 else { return false }

        if shift < 8 {
            guard slabTransitionPageBit(
                page        : page,
                blockIndex  : blockIndex,
                expectedLive: false
            ) else { return false }
        } else {
            let mask = UInt16(1) << UInt16(blockIndex)
            guard (liveBits[index] & mask) == 0 else { return false }
            liveBits[index] |= mask
        }

        freeCounts[index] -= 1
        return true
    }
    
    @inline(__always)
    mutating func onFreeBlock(
        page      : UnsafeMutableRawPointer,
        blockIndex: Int,
        shift     : UInt8
    ) -> SlabFreeResult {
        let index = pageIndex(page)
        let blockCount = 4096 / (1 << Int(shift))
        let reserved = SlabCore<Self>.reservedBlockCount(forShift: shift)
        let usableCount = UInt16(blockCount - reserved)
        guard freeCounts[index] < usableCount else { return .invalid }

        if shift < 8 {
            guard slabTransitionPageBit(
                page        : page,
                blockIndex  : blockIndex,
                expectedLive: true
            ) else { return .invalid }
        } else {
            let mask = UInt16(1) << UInt16(blockIndex)
            guard (liveBits[index] & mask) != 0 else { return .invalid }
            liveBits[index] &= ~mask
        }

        freeCounts[index] += 1
        return freeCounts[index] == usableCount ? .releasePage : .retained
    }
    
    @inline(__always)
    private func pageIndex(_ page: UnsafeMutableRawPointer) -> Int {
        Int((UInt(bitPattern: page) - arenaBase) >> 12)
    }
}
