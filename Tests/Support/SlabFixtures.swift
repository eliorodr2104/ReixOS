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
    private var rejectNextAllocation = false
    private var retainNextRelease = false

    /// Pages handed out and not yet given back.
    public var livePages: Int { acquiredPages - releasedPages }

    /// Still-free blocks on the page `pointer` belongs to, the number
    /// `FrameInfo.heapFreeCount` holds on the real machine.
    public func freeBlocks(onPageOf pointer: UnsafeMutableRawPointer) -> UInt16 {
        states[key(SlabCore<Self>.pageBase(pointer))]?.freeCount ?? 0
    }

    /// Every page bound to a class and not yet released, with its shift.
    public var boundPages: [(page: UnsafeMutableRawPointer, shift: UInt8)] {
        states.sorted { $0.key < $1.key }.map {
            (UnsafeMutableRawPointer(bitPattern: $0.key)!, $0.value.shift)
        }
    }

    /// The pool's first page, for tests that write into it on purpose.
    public var poolBase: UnsafeMutableRawPointer { arena }

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

    public mutating func rejectOneAllocation() { rejectNextAllocation = true }
    public mutating func retainOneReleasedPage() { retainNextRelease = true }


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


    public mutating func releasePage(_ page: UnsafeMutableRawPointer) -> Bool {
        if retainNextRelease {
            retainNextRelease = false
            return false
        }
        states[key(page)] = nil
        recycled.append(page)
        releasedPages += 1
        return true
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


    public func largeLiveBits(ofPage page: UnsafeMutableRawPointer) -> UInt16 {
        states[key(page)]?.allocationBits ?? UInt16.max
    }


    public mutating func onAllocBlock(
        page      : UnsafeMutableRawPointer,
        blockIndex: Int,
        shift     : UInt8
    ) -> Bool {
        if rejectNextAllocation {
            rejectNextAllocation = false
            return false
        }
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
    _ body: (inout SlabCore<HostSlabBackend>) throws -> Void
) rethrows {
    var core = SlabCore(backend: HostSlabBackend(pages: pages))
    defer { core.backend.release() }
    try body(&core)
}


/// Every way `core`'s lists and the backend's liveness can disagree, as one
/// line each; empty when they agree. Run after every step of a stress.
///
/// `boundPages` are the pages the backend holds for the core, `freeCount` the
/// backend's own free count for one of them, and `live` the address of every
/// block the caller believes is live. Pages listed in `retainedEmpty` are empty
/// pages the backend refused to take back, which stay bound off every list.
public func slabInvariantViolations<Backend: SlabBackend>(
    _ core       : SlabCore<Backend>,
    boundPages   : [(page: UnsafeMutableRawPointer, shift: UInt8)],
    freeCount    : (UnsafeMutableRawPointer) -> Int,
    live         : Set<UInt>,
    retainedEmpty: Set<UInt> = []
) -> [String] {
    typealias Core = SlabCore<Backend>
    var backend  = core.backend
    var problems: [String] = []
    var listable: [UInt8: Set<UInt>] = [:]
    var liveSeen = 0

    if core.reservedPages != UInt(boundPages.count) {
        problems.append("reservedPages \(core.reservedPages) but \(boundPages.count) pages bound")
    }

    for (page, shift) in boundPages {
        let name     = "page 0x\(String(UInt(bitPattern: page), radix: 16)) shift \(shift)"
        let blocks   = Core.pageSize >> Int(shift)
        let reserved = Core.reservedBlockCount(forShift: shift)
        let state    = core.pageState(page, shift: shift)

        var liveBlocks: [Int] = []
        for block in reserved..<blocks {
            let isLive = shift < Core.largeShift
                ? slabPageBitIsSet(page: page, blockIndex: block)
                : backend.largeLiveBits(ofPage: page) & (UInt16(1) << UInt16(block)) != 0
            if isLive { liveBlocks.append(block) }

            let address = UInt(bitPattern: page) + UInt(block << Int(shift))
            if isLive != live.contains(address) {
                problems.append("\(name) block \(block) live=\(isLive), caller disagrees")
            }
        }
        liveSeen += liveBlocks.count

        let free = blocks - reserved - liveBlocks.count
        if freeCount(page) != free {
            problems.append("\(name) backend free count \(freeCount(page)), bitmap says \(free)")
        }
        if liveBlocks.isEmpty && !retainedEmpty.contains(UInt(bitPattern: page)) {
            problems.append("\(name) is empty and still bound")
        }

        if shift < Core.largeShift {
            let nodes = state.freeBlocks
            if Set(nodes).count != nodes.count { problems.append("\(name) free list repeats a block") }
            if state.bump <= reserved || state.bump > blocks {
                problems.append("\(name) bump \(state.bump) outside \(reserved + 1)...\(blocks)")
            }
            for node in nodes where node < reserved || node >= state.bump || liveBlocks.contains(node) {
                problems.append("\(name) free list holds block \(node)")
            }
            for block in liveBlocks where block >= state.bump {
                problems.append("\(name) live block \(block) at or past bump \(state.bump)")
            }
            if nodes.count + blocks - state.bump != free
                && !retainedEmpty.contains(UInt(bitPattern: page)) {
                problems.append("\(name) reaches \(nodes.count + blocks - state.bump) free blocks of \(free)")
            }
            if !nodes.isEmpty || state.bump < blocks {
                listable[shift, default: []].insert(UInt(bitPattern: page))
            }
        } else if free > 0 {
            listable[shift, default: []].insert(UInt(bitPattern: page))
        }
    }

    if liveSeen != live.count {
        problems.append("caller holds \(live.count) live blocks, pages hold \(liveSeen)")
    }

    for shift in Core.minShift...12 {
        let list = core.partialPages(shift: shift)
        let addresses = list.map { UInt(bitPattern: $0) }
        let expected = (listable[shift] ?? []).subtracting(retainedEmpty)

        if Set(addresses).count != addresses.count { problems.append("shift \(shift) list repeats a page") }
        if Set(addresses) != expected {
            problems.append("shift \(shift) list \(addresses.count) pages, \(expected.count) have free blocks")
        }
        for (index, page) in list.enumerated() {
            let state = core.pageState(page, shift: shift)
            let prev  = index == 0 ? nil : list[index - 1]
            let next  = index + 1 == list.count ? nil : list[index + 1]
            if state.prev != prev || state.next != next {
                problems.append("shift \(shift) list position \(index) has broken links")
            }
        }
    }

    return problems
}
