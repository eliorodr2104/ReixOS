//
//  FrameBudget.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 12/09/2026.
//

/// What one process may make the kernel hold in physical frames, and what it
/// currently does hold.
///
/// Counted in 4 KiB frames and not in bytes, because every charge point hands
/// out whole frames and a page is the unit the physical page manager issues.
/// Counted per *reference* and not per frame: a page two address spaces share
/// through a clone is a claim each of them makes on the machine, so each pays
/// for it, and the copy that later replaces one of those claims costs a page
/// and gives the shared one back.
///
/// A heap cell of its own, reference counted, and pointed at by
/// `ProcessMetadata.budget`. It is not inline in the metadata because a
/// `SharedRegion` outlives the process that created it whenever somebody else
/// still holds the region: the creator is charged for the region's whole life,
/// so the region has to be able to give those frames back to a budget that is
/// still there to receive them. The process holds one reference and every
/// region that names it holds one more, so the last of them frees the cell.
///
/// `UInt32` throughout: 16 TiB of frames, more than the 39-bit user window can
/// map, and the whole cell fits the smallest slab bucket.
public struct FrameBudget: RXObject {

    public static var errorMessageAllocation: StaticString = "Failed to allocate FrameBudget on the kernel heap"

    /// The process, plus one per shared region charged against it.
    public var references: UInt32

    /// Frames this process may hold at once. `UInt32.max` is the machine's own
    /// ceiling, which only the boot path hands out.
    public var limit: UInt32 // 4 Byte

    /// Frames the kernel currently holds on this process's behalf.
    public var charged: UInt32 // 4 Byte


    public init(
        limit     : UInt32 = .max,
        charged   : UInt32 = 0,
        references: UInt32 = 1
    ) {
        self.limit      = limit
        self.charged    = charged
        self.references = references
    }


    /// Take `pages` against the limit, or refuse without taking any.
    ///
    /// One checked add: an overflow is a refusal and not a wrap, because a
    /// wrapped total reads as a process holding almost nothing and would let
    /// the next request through.
    @inline(__always)
    public mutating func charge(_ pages: UInt32) -> Bool {
        let (total, overflow) = charged.addingReportingOverflow(pages)

        guard !overflow, total <= limit else { return false }

        charged = total
        return true
    }


    /// Give `pages` back.
    ///
    /// Clamped at zero rather than wrapped, for `VMAManager.noteRetired`'s
    /// reason: a refund without its charge is a bug worth finding, and zero is
    /// where it shows instead of four billion.
    @inline(__always)
    public mutating func refund(_ pages: UInt32) {
        charged = pages >= charged ? 0 : charged &- pages
    }


    /// A child's limit, attenuated against this one.
    ///
    /// Monotone like capability attenuation: a request above what the creator
    /// itself may hold is clamped and not refused, so no subtree sum is ever
    /// needed to know that a tree cannot exceed its root. `nil` is a child that
    /// asked for nothing and inherits.
    @inline(__always)
    public func attenuated(to requested: UInt32?) -> UInt32 {
        guard let requested else { return limit }

        return requested < limit ? requested : limit
    }
}


/// Drop one hold on `budget`, freeing the cell once nobody holds it.
@inline(__always)
func releaseBudget(
    _ budget: UnsafeMutablePointer<FrameBudget>,
    heap    : UnsafeMutablePointer<KernelHeap>
) {
    guard rxRelease(budget) else { return }

    heap.pointee.kfree(UnsafeMutableRawPointer(budget))
}


/// Charge `pages` to `budget`, or refuse. A charge point with no budget to
/// answer to is one the kernel makes for itself; see the allow-list in
/// `FrameBudgetSiteTests`.
@inline(__always)
func chargeFrames(
    _ budget: UnsafeMutablePointer<FrameBudget>?,
    _ pages : UInt32
) -> Bool {
    guard let budget else { return true }

    return budget.pointee.charge(pages)
}


/// Give `pages` back to `budget`, the exact counterpart of `chargeFrames`.
@inline(__always)
func refundFrames(
    _ budget: UnsafeMutablePointer<FrameBudget>?,
    _ pages : UInt32
) {
    budget?.pointee.refund(pages)
}
