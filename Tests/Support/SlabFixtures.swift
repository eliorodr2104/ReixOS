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
        var shift    : UInt8
        var freeCount: UInt16
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


    public mutating func bind(
        page : UnsafeMutableRawPointer,
        shift: UInt8
    ) {
        states[key(page)] = PageState(
            shift    : shift,
            freeCount: UInt16(Self.pageSize / (1 << Int(shift)) - 1)
        )
    }


    public func shift(ofPage page: UnsafeMutableRawPointer) -> UInt8 {
        states[key(page)]?.shift ?? 0
    }


    public mutating func onAllocBlock(page: UnsafeMutableRawPointer) {
        guard var state = states[key(page)], state.freeCount > 0 else { return }

        state.freeCount -= 1
        states[key(page)] = state
    }


    public mutating func onFreeBlock(page: UnsafeMutableRawPointer) -> Bool {
        guard var state = states[key(page)] else { return false }

        state.freeCount += 1
        states[key(page)] = state

        return state.freeCount >= UInt16(Self.pageSize / (1 << Int(state.shift)))
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
