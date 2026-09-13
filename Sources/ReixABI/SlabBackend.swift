//
//  SlabBackend.swift
//  ReixOS
//
//  Created by Eliomar on 21/06/2026.
//

public enum SlabFreeResult {
    case invalid
    case retained
    case releasePage
}

public protocol SlabBackend {
    
    mutating func acquirePage() -> UnsafeMutableRawPointer?
    mutating func releasePage(_ page: UnsafeMutableRawPointer)

    mutating func bind(page: UnsafeMutableRawPointer, shift: UInt8)
    /// Returns nil before indexing metadata when the page is foreign, released,
    /// or not currently a slab page.
    func shiftIfOwned(ofPage page: UnsafeMutableRawPointer) -> UInt8?

    func isAllocatedBlock(
        page      : UnsafeMutableRawPointer,
        blockIndex: Int,
        shift     : UInt8
    ) -> Bool

    /// Validate and perform one liveness / count transition. The heap remains
    /// single-writer; this combines metadata work rather than adding synchronization.
    /// Keeping each hot-path transition in one witness call matters across modules.
    mutating func onAllocBlock(
        page      : UnsafeMutableRawPointer,
        blockIndex: Int,
        shift     : UInt8
    ) -> Bool
    mutating func onFreeBlock(
        page      : UnsafeMutableRawPointer,
        blockIndex: Int,
        shift     : UInt8
    ) -> SlabFreeResult
}

@inline(__always)
public func slabPageBitIsSet(
    page      : UnsafeMutableRawPointer,
    blockIndex: Int
) -> Bool {
    let word = page.load(
        fromByteOffset: (blockIndex >> 6) * 8,
        as: UInt64.self
    )
    return (word & (UInt64(1) << UInt64(blockIndex & 63))) != 0
}

/// Changes one bit in the page-resident small-bucket bitmap only when it is in
/// `expectedLive`. Returns false without a write if the transition is invalid.
@inline(__always)
public func slabTransitionPageBit(
    page        : UnsafeMutableRawPointer,
    blockIndex  : Int,
    expectedLive: Bool
) -> Bool {
    let offset = (blockIndex >> 6) * 8
    let mask = UInt64(1) << UInt64(blockIndex & 63)
    var word = page.load(fromByteOffset: offset, as: UInt64.self)
    let live = (word & mask) != 0
    guard live == expectedLive else { return false }

    word = expectedLive ? word & ~mask : word | mask
    page.storeBytes(of: word, toByteOffset: offset, as: UInt64.self)
    return true
}

/// The next representable power of two, or zero when rounding would overflow.
/// Exact powers of two, including the top bit, remain representable.
@inline(__always)
public func roundUpPow2(_ value: UInt) -> UInt {
    guard value > 1 else { return value }
    guard (value & (value - 1)) != 0 else { return value }

    let shift = UInt.bitWidth - value.leadingZeroBitCount
    guard shift < UInt.bitWidth else { return 0 }

    return UInt(1) << shift
}
