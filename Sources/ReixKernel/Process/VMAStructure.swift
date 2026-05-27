//
//  VMAStructure.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

/// Contract every container backing a process VMA set must satisfy.
///
/// The protocol stays intentionally minimal: lookup (point and range),
/// insertion/removal, gap finding, plus the structural operations
/// (`split`, `mergeAdjacent`) needed to support partial mmap/munmap.
/// The backing data structure is interchangeable: the current
/// implementation is a doubly-linked list (`VMAList`), a balanced tree
/// will land once profiling justifies it.
public protocol VMAStructure {

    func search(at address: VirtualAddress) -> UnsafeMutablePointer<VirtualMemoryArea>?

    /// Returns the first VMA whose range intersects the half-open
    /// interval `[start, end)`. `nil` means the range is fully free.
    func searchOverlap(
        start: VirtualAddress,
        end  : VirtualAddress
    ) -> UnsafeMutablePointer<VirtualMemoryArea>?

    mutating func insert(_ region: UnsafeMutablePointer<VirtualMemoryArea>)
    mutating func delete(at address: VirtualAddress)

    /// Find a free aligned gap large enough for `size` bytes between
    /// the structure global `minAddress` and `maxAddress`.
    func findFreeGAP(
        size     : UInt64,
        alignment: UInt64
    ) -> VirtualAddress?

    /// Find a free aligned gap large enough for `size` bytes within a
    /// caller-provided range, scanning in the requested direction.
    /// Used to keep brk (upward) and mmap (downward) within disjoint
    /// regions of the user VA space.
    func findFreeGAPInRange(
        min      : VirtualAddress,
        max      : VirtualAddress,
        size     : UInt64,
        alignment: UInt64,
        direction: GapDirection
    ) -> VirtualAddress?

    /// Split `region` into two adjacent VMAs at `address`. The original
    /// node keeps `[startAddress, address)` and the returned new node
    /// covers `[address, endAddress)` with identical attributes.
    ///
    /// The heap is passed explicitly so the caller is in control of the
    /// allocation lifetime and the structure stays decoupled from any
    /// hidden global heap.
    mutating func split(
        _ region  : UnsafeMutablePointer<VirtualMemoryArea>,
        at        : VirtualAddress,
        using heap: UnsafeMutablePointer<BucketsHeap>
    ) throws(VMAError) -> UnsafeMutablePointer<VirtualMemoryArea>

    /// Fuse two adjacent VMAs with identical attributes into the first
    /// one. Returns the node that has been unlinked from the list and
    /// must be freed by the caller (it is `second`'s pointer). Returns
    /// `nil` when the two VMAs are not mergeable.
    mutating func mergeAdjacent(
        _ first : UnsafeMutablePointer<VirtualMemoryArea>,
        _ second: UnsafeMutablePointer<VirtualMemoryArea>
    ) -> UnsafeMutablePointer<VirtualMemoryArea>?
}
