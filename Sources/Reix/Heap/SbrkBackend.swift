//
//  SbrkBackend.swift
//  ReixOS
//
//  Created by Eliomar on 21/06/2026.
//

import ReixABI

struct SbrkBackend: SlabBackend {
    static let maxArenaPages = 1024 // cap: 1024 * 4 KiB = 4 MiB heap

    var shifts    : InlineArray = InlineArray<1024, UInt8 >(repeating: 0)
    var freeCounts: InlineArray = InlineArray<1024, UInt16>(repeating: 0)
    var freePages : InlineArray = InlineArray<1024, UInt  >(repeating: 0)
    
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
            return UnsafeMutableRawPointer(bitPattern: freePages[Int(freeTop)])
        }
        
        let prev = sbrk(4096)
        if prev == RX_MEM_FAILURE { return nil }
        
        arenaEnd = UInt(brk(0))
        
        let idx = (UInt(prev) - arenaBase) >> 12
        guard idx < UInt(Self.maxArenaPages) else { return nil }
        
        return UnsafeMutableRawPointer(bitPattern: UInt(prev))
    }
    
    mutating func releasePage(_ page: UnsafeMutableRawPointer) {
        _ = decommit(addr: UInt64(UInt(bitPattern: page)), size: 4096)
        
        freePages[Int(freeTop)] = UInt(bitPattern: page)
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
