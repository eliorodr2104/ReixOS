//
//  FreeBlock.swift
//  ReixOS
//
//  Created by Eliomar on 22/08/2026.
//


/// Intrusive free-list node overlaid on a free block's first 16 bytes.
///
/// The buddy free lists thread through the free blocks themselves (no extra
/// allocation: the allocator can't allocate to track its own free list), so
/// `FreeBlock` is materialised at a block's physical address and linked via a
/// `LinkedList<FreeBlock>`. Being doubly linked, unlinking an arbitrary buddy
/// during a merge is O(1). `entryID` is unused: the buddy never does id-based
/// lookups, only `pushBack`/`popFront`/`remove(element:)`.
public struct FreeBlock: RXEntry {
    public static var errorMessageAllocation: StaticString = "FreeBlock"
    public var prev: UnsafeMutablePointer<FreeBlock>?
    public var next: UnsafeMutablePointer<FreeBlock>?
    public var entryID: UInt64 { 0 }
}