import ReixHeapHostShims
import Reix

@_silgen_name("reix_malloc")
private func reixMalloc(_ size: UInt) -> UnsafeMutableRawPointer?

@_silgen_name("reix_free")
private func reixFree(_ pointer: UnsafeMutableRawPointer?)

@_silgen_name("reix_posix_memalign")
private func reixPosixMemalign(
    _ output   : UnsafeMutablePointer<UnsafeMutableRawPointer?>,
    _ alignment: UInt,
    _ size     : UInt
) -> Int32

private func require(
    _ condition: Bool,
    _ message  : StaticString,
      file     : StaticString = #fileID,
      line     : UInt = #line
) {
    if !condition { fatalError("\(message) at \(file):\(line)") }
}

private func samePage(
    _ first : UnsafeMutableRawPointer?,
    _ second: UnsafeMutableRawPointer?
) -> Bool {
    (UInt(bitPattern: first) & ~UInt(0xFFF))
        == (UInt(bitPattern: second) & ~UInt(0xFFF))
}

reix_heap_host_reset()

// Zero is page-aligned but cannot be an arena base. Refuse it without publishing
// started state or mutating the process break, then allow a later retry.
reix_heap_host_zero_next_break_query()
require(reixMalloc(4096) == nil, "zero initial break was accepted")
require(reix_heap_host_break_offset() == 0, "zero initial break moved the break")
require(reix_heap_host_break_set_count() == 0, "zero initial break issued growth")

require(sbrk(Int64.max) == UInt64.max, "positive sbrk overflow was accepted")
require(sbrk(Int64.min) == UInt64.max, "negative sbrk overflow was accepted")
require(reix_heap_host_break_offset() == 0, "sbrk overflow moved the break")
require(reix_heap_host_break_set_count() == 0, "sbrk overflow issued growth")
let syscallsBeforeArithmetic = reix_heap_host_syscall_count()

// Arithmetic refusals happen before the arena starts or any syscall state moves.
require(reixMalloc(UInt.max) == nil, "UInt.max allocation was accepted")
require(reixMalloc((UInt(1) << (UInt.bitWidth - 1)) + 1) == nil, "pow2 overflow was accepted")
var aligned: UnsafeMutableRawPointer? = nil
require(
    reixPosixMemalign(&aligned, UInt(1) << (UInt.bitWidth - 1), 1) == 12,
    "unserviceable alignment did not report ENOMEM"
)
require(aligned == nil, "failed posix_memalign changed its output")
require(
    reix_heap_host_syscall_count() == syscallsBeforeArithmetic,
    "arithmetic refusal invoked a syscall"
)

let syscallsBeforeOOM = reix_heap_host_syscall_count()
require(reixMalloc(8192) == nil, "failed mmap was accepted")
require(
    reix_heap_host_syscall_count() == syscallsBeforeOOM + 1,
    "large-allocation OOM did not make exactly one mmap request"
)

reix_heap_host_enable_large_mapping()
let large = reixMalloc(8192)
require(large != nil, "host large mapping was not allocated")
require(userHeapReservedBytes() == 8192, "large reservation was not accounted")
reix_heap_host_fail_munmap(1)
reixFree(large)
require(reix_heap_host_munmap_count() == 1, "failed large release did not call munmap")
require(userHeapReservedBytes() == 8192, "failed large release erased its reservation")
reixFree(large)
require(reix_heap_host_munmap_count() == 2, "large release was not retryable")
require(userHeapReservedBytes() == 0, "successful large release retained its reservation")
require(userHeapHighWaterBytes() >= 8192, "large reservation high-water mark was not recorded")

// A failed decommit retains backing but still clears the old slab class and
// recycles the empty page exactly once.
reix_heap_host_fail_decommit(1)
let first = reixMalloc(2048)
let second = reixMalloc(2048)
require(first != nil && second != nil && first != second, "initial slab allocations failed")
require(samePage(first, second), "2048-byte blocks did not share their page")
reixFree(first)
reixFree(second)
require(reix_heap_host_decommit_count() == 1, "empty page was not decommitted once")

// Once released, the old address is no longer live. This duplicate free must not
// republish the page index or poison the free list.
reixFree(first)
let third = reixMalloc(2048)
let fourth = reixMalloc(2048)
require(third != nil && fourth != nil && third != fourth, "recycled page aliased allocations")
require(samePage(first, third) && samePage(third, fourth), "empty page was not recycled")

reixFree(third)
reixFree(fourth)
require(reix_heap_host_decommit_count() == 2, "repeated release did not decommit once")

let fifth = reixMalloc(2048)
let sixth = reixMalloc(2048)
require(fifth != nil && sixth != nil && fifth != sixth, "second page reuse aliased allocations")

// A malformed break query must fail this growth without widening arena metadata
// bounds. A subsequent normal query can still grow by one contiguous page.
reix_heap_host_malformed_next_break_query()
require(reixMalloc(4096) == nil, "malformed break growth was accepted")
let wholePage = reixMalloc(4096)
require(wholePage != nil, "valid growth after malformed response did not recover")

// A bad query scheduled after a successful growth is observed by the next
// transaction, before another brk mutation. It may refuse one request, but it
// cannot repeatedly advance the process break or leak arena capacity.
reix_heap_host_malformed_query_after_next_growth()
let afterGrowth = reixMalloc(4096)
require(afterGrowth != nil, "exact direct growth result was not accepted")
let breakAfterGrowth = reix_heap_host_break_offset()
let setsAfterGrowth = reix_heap_host_break_set_count()
require(reixMalloc(4096) == nil, "malformed post-growth query was accepted")
require(reix_heap_host_break_offset() == breakAfterGrowth, "failed query advanced the break")
require(reix_heap_host_break_set_count() == setsAfterGrowth, "failed query issued another growth")
let afterRecovery = reixMalloc(4096)
require(afterRecovery != nil, "growth did not recover after malformed query")
require(
    reix_heap_host_break_offset() == breakAfterGrowth + 4096,
    "recovery advanced by more than one page"
)

reixFree(fifth)
reixFree(sixth)
reixFree(wholePage)
reixFree(afterGrowth)
reixFree(afterRecovery)

// Every class through posix_memalign, so 8 bytes is a class of its own: a page
// holds exactly its usable blocks and is decommitted at its last free, no sooner.
private func allocClass(_ size: UInt) -> UnsafeMutableRawPointer? {
    var output: UnsafeMutableRawPointer? = nil
    return reixPosixMemalign(&output, 8, size) == 0 ? output : nil
}

let usableBlocks: [(UInt, Int)] = [
    (8, 501), (16, 252), (32, 126), (64, 63), (128, 31),
    (256, 16), (512, 8), (1024, 4), (2048, 2), (4096, 1),
]
for (size, count) in usableBlocks {
    let decommits = reix_heap_host_decommit_count()
    let blocks = (0..<count).map { _ in allocClass(size)! }
    require(blocks.allSatisfy { samePage($0, blocks[0]) }, "a class page did not hold its usable blocks")
    require(Set(blocks.map { UInt(bitPattern: $0) }).count == count, "a class page aliased its blocks")

    let spill = allocClass(size)
    require(spill != nil && !samePage(spill, blocks[0]), "a full page served a block past its usable count")
    reixFree(spill)
    require(reix_heap_host_decommit_count() == decommits + 1, "the one-block spill page was not released")

    for (index, block) in blocks.enumerated() {
        reixFree(block)
        let expected = decommits + 1 + (index + 1 == count ? 1 : 0)
        require(reix_heap_host_decommit_count() == expected, "a page was not released exactly at its last free")
    }
}

// Three partial pages; emptying the middle one releases it at once, and the two
// left keep serving the class without growing the arena.
let breakBeforeLists = reix_heap_host_break_offset()
var listPages = (0..<3).map { _ in (0..<63).map { _ in allocClass(64)! } }
for page in listPages { reixFree(page[0]) }
let decommitsBeforeMiddle = reix_heap_host_decommit_count()
for block in listPages[1].dropFirst() { reixFree(block) }
require(reix_heap_host_decommit_count() == decommitsBeforeMiddle + 1, "emptied middle page was not released")
let refillA = allocClass(64)
let refillB = allocClass(64)
require(
    samePage(refillA, listPages[2][1]) && samePage(refillB, listPages[0][1]),
    "remaining partial pages were not served head first"
)
require(reix_heap_host_break_offset() == breakBeforeLists, "partial pages were bypassed by arena growth")
listPages[2][0] = refillA!
listPages[0][0] = refillB!
for block in listPages[0] + listPages[2] { reixFree(block) }

// A fixed-seed stress over every class: payloads survive, no block is handed out
// twice, and after the drain every arena page is free again for any class.
var stressState: UInt64 = 0x5B4C_0001
var stressLive: [(UnsafeMutableRawPointer, UInt64)] = []
var stressAddresses: Set<UInt> = []
for step in 0..<6000 {
    stressState = stressState &* 6364136223846793005 &+ 1442695040888963407
    let growing = (step / 750) % 2 == 0
    if stressLive.isEmpty || (stressState >> 33) % 4 < (growing ? 3 : 1) {
        let size = max(UInt(1) << UInt((stressState >> 40) % 10 + 3) - UInt((stressState >> 50) & 1), 1)
        guard let block = allocClass(size) else { continue }
        require(stressAddresses.insert(UInt(bitPattern: block)).inserted, "stress handed out a live block")
        let pattern = UInt64(step) | 0xFEED_0000_0000_0000
        block.storeBytes(of: pattern, as: UInt64.self)
        stressLive.append((block, pattern))
    } else {
        let index = Int((stressState >> 20) % UInt64(stressLive.count))
        let (block, pattern) = stressLive.remove(at: index)
        require(block.load(as: UInt64.self) == pattern, "stress payload was overwritten")
        stressAddresses.remove(UInt(bitPattern: block))
        reixFree(block)
    }
}
for (block, pattern) in stressLive {
    require(block.load(as: UInt64.self) == pattern, "stress payload was overwritten")
    reixFree(block)
}

var wholePages: [UnsafeMutableRawPointer] = []
while let page = allocClass(4096) { wholePages.append(page) }
require(wholePages.count == 64, "drained arena did not return every page")
for page in wholePages { reixFree(page) }

print("Sbrk heap harness passed")
