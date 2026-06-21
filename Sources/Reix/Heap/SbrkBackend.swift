//
//  SbrkBackend.swift
//  ReixOS
//
//  Created by Eliomar on 21/06/2026.
//

import ReixABI

struct SbrkBackend: SlabBackend {
    static let maxArenaPages = 1024 // cap: 1024 * 4 KiB = 4 MiB heap

    var arenaBase: UInt        = 0
    var arenaEnd : UInt        = 0
    var started  : Bool        = false
    var shifts   : InlineArray = InlineArray<1024, UInt8>(repeating: 0)

    @inline(__always)
    private mutating func ensureStarted() {
        if started { return }
        
        arenaBase = UInt(brk(0))
        arenaEnd  = arenaBase
        started   = true
    }

    mutating func acquirePage() -> UnsafeMutableRawPointer? {
        ensureStarted()
        
        let prev = sbrk(4096)
        if prev == RX_MEM_FAILURE { return nil }
        
        arenaEnd = UInt(brk(0))
        
        let idx = (UInt(prev) - arenaBase) >> 12
        guard idx < UInt(Self.maxArenaPages) else { return nil }
        
        return UnsafeMutableRawPointer(bitPattern: UInt(prev))
    }
    
    // TODO: Implement this
    func releasePage(_ page: UnsafeMutableRawPointer) {
        
    }
    
    @inline(__always)
    mutating func bind(
        page : UnsafeMutableRawPointer,
        shift: UInt8
    ) { shifts[pageIndex(page)] = shift }
    
    @inline(__always)
    func shift(ofPage page: UnsafeMutableRawPointer) -> UInt8 {
        shifts[pageIndex(page)]
    }

    // TODO: Implement this
    func onAllocBlock(page: UnsafeMutableRawPointer) {
        
    }
    
    // TODO: Implement this
    func onFreeBlock(page: UnsafeMutableRawPointer) -> Bool {
        false
    }
    
    @inline(__always)
    private func pageIndex(_ page: UnsafeMutableRawPointer) -> Int {
        Int((UInt(bitPattern: page) - arenaBase) >> 12)
    }
}
