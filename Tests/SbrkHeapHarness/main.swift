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

print("Sbrk heap harness passed")
