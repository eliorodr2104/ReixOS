//
//  SlabFixtures.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.

import ReixABI

/// Pool-backed `SlabBackend` over page-aligned host memory.
///
/// The counters are the assertions' window into the slab: `acquiredPages` and
/// `releasedPages` say when the core went to the page source and when it gave a
/// page back, which is the accounting `FrameInfo.heapFreeCount` performs on the
/// real machine.
public struct HostSlabBackend: SlabBackend {

    public static let pageSize: Int = 4096

    /// Per-page state, keyed by page base address.
    private struct PageState {
        var shift         : UInt8
        var freeCount     : UInt16
        var allocationBits: UInt16
    }

    public private(set) var acquiredPages = 0
    public private(set) var releasedPages = 0

    /// Pages handed out and not yet given back.
    public var livePages: Int { acquiredPages - releasedPages }

    /// Still-free blocks on the page `pointer` belongs to, the number
    /// `FrameInfo.heapFreeCount` holds on the real machine.
    public func freeBlocks(onPageOf pointer: UnsafeMutableRawPointer) -> UInt16 {
        states[key(SlabCore<Self>.pageBase(pointer))]?.freeCount ?? 0
    }

    private let arena   : UnsafeMutableRawPointer
    private let capacity: Int

    private var handedOut = 0
    private var recycled  : [UnsafeMutableRawPointer] = []
    private var states    : [UInt: PageState] = [:]


    public init(pages: Int) {
        self.capacity = pages
        self.arena    = UnsafeMutableRawPointer.allocate(
            byteCount: pages * Self.pageSize,
            alignment: Self.pageSize
        )
        arena.initializeMemory(as: UInt8.self, repeating: 0, count: pages * Self.pageSize)
    }


    /// Frees the pool. The blocks the core still holds become dangling, so call it
    /// only once the core is out of use.
    public func release() { arena.deallocate() }


    public mutating func acquirePage() -> UnsafeMutableRawPointer? {
        let page: UnsafeMutableRawPointer

        if let recycledPage = recycled.popLast() {
            page = recycledPage

        } else {
            guard handedOut < capacity else { return nil }

            page = arena + handedOut * Self.pageSize
            handedOut += 1
        }

        acquiredPages += 1
        return page
    }


    public mutating func releasePage(_ page: UnsafeMutableRawPointer) {
        states[key(page)] = nil
        recycled.append(page)
        releasedPages += 1
    }


    public func owns(page: UnsafeMutableRawPointer) -> Bool {
        states[key(page)] != nil
    }


    public mutating func bind(
        page : UnsafeMutableRawPointer,
        shift: UInt8
    ) {
        let blockCount = Self.pageSize / (1 << Int(shift))
        let reserved = SlabCore<Self>.reservedBlockCount(forShift: shift)
        states[key(page)] = PageState(
            shift         : shift,
            freeCount     : UInt16(blockCount - reserved),
            allocationBits: 0
        )
    }


    public func shiftIfOwned(ofPage page: UnsafeMutableRawPointer) -> UInt8? {
        states[key(page)]?.shift
    }


    public func isAllocatedBlock(
        page      : UnsafeMutableRawPointer,
        blockIndex: Int,
        shift     : UInt8
    ) -> Bool {
        if shift < 8 { return slabPageBitIsSet(page: page, blockIndex: blockIndex) }

        return (states[key(page)]!.allocationBits
            & (UInt16(1) << UInt16(blockIndex))) != 0
    }


    public mutating func onAllocBlock(
        page      : UnsafeMutableRawPointer,
        blockIndex: Int,
        shift     : UInt8
    ) -> Bool {
        guard var state = states[key(page)], state.freeCount > 0 else { return false }

        if shift < 8 {
            guard slabTransitionPageBit(
                page        : page,
                blockIndex  : blockIndex,
                expectedLive: false
            ) else { return false }
        } else {
            let mask = UInt16(1) << UInt16(blockIndex)
            guard (state.allocationBits & mask) == 0 else { return false }
            state.allocationBits |= mask
        }

        state.freeCount -= 1
        states[key(page)] = state
        return true
    }


    public mutating func onFreeBlock(
        page      : UnsafeMutableRawPointer,
        blockIndex: Int,
        shift     : UInt8
    ) -> SlabFreeResult {
        guard var state = states[key(page)] else { return .invalid }

        let blockCount = Self.pageSize / (1 << Int(state.shift))
        let reserved = SlabCore<Self>.reservedBlockCount(forShift: state.shift)
        let usableCount = UInt16(blockCount - reserved)
        guard state.freeCount < usableCount else { return .invalid }

        if shift < 8 {
            guard slabTransitionPageBit(
                page        : page,
                blockIndex  : blockIndex,
                expectedLive: true
            ) else { return .invalid }
        } else {
            let mask = UInt16(1) << UInt16(blockIndex)
            guard (state.allocationBits & mask) != 0 else { return .invalid }
            state.allocationBits &= ~mask
        }

        state.freeCount += 1
        states[key(page)] = state

        return state.freeCount == usableCount ? .releasePage : .retained
    }


    private func key(_ page: UnsafeMutableRawPointer) -> UInt {
        UInt(bitPattern: page)
    }
}


/// Runs `body` over a `SlabCore` on a pool of `pages` pages, then frees the pool.
public func withSlabCore(
    pages : Int,
    _ body: (inout SlabCore<HostSlabBackend>) -> Void
) {
    var core = SlabCore(backend: HostSlabBackend(pages: pages))
    body(&core)
    core.backend.release()
}
