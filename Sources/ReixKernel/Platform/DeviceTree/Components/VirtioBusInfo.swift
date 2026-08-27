//
//  VirtioBusInfo.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

/// The virtio-mmio transports, as the device tree describes them, one by one.
///
/// This was two ranges: the span from the lowest window to the highest, and the
/// block from the lowest line to the highest. Merging is lossy in a way that
/// hands out authority nobody meant to give. Any hole between two windows became
/// a delegable window; any interrupt number that happened to fall between two
/// virtio lines became claimable, including one belonging to a different device
/// entirely; and the line of a transport was taken to be its position on the bus
/// plus the first line, which is true of this machine and of no rule.
///
/// The merging was also order dependent. A window arriving with a lower base
/// than one already seen moved the start of the span without extending its
/// length, so the transport at the top simply vanished - and the device tree
/// says nothing about the order in which it lists its nodes.
///
/// A list of exactly what the blob said has none of those properties, and a
/// transport is named by its index in it, so there is no offset to get wrong.
public struct VirtioBusInfo {

    /// How many transports fit. QEMU's `virt` has thirty-two; a machine with
    /// more gets its first thirty-two, and says so rather than growing a
    /// kernel-heap allocation into the middle of the device tree walk.
    public static let capacity = 32

    /// Kept sorted by base, so what the walk finds does not depend on the order
    /// the blob happened to list its nodes in.
    var slots = InlineArray<32, VirtioTransport>(repeating: VirtioTransport())

    public private(set) var count: UInt32 = 0

    /// Transports the blob described and this refused: overlapping windows, a
    /// line claimed twice, or more than there is room for. Not a fault, because
    /// a machine is whatever it is, but not silence either.
    public private(set) var rejected: UInt32 = 0

    public var isPresent: Bool { count != 0 }

    public init() {}


    /// The `index`th transport, counting from the lowest window.
    public func transport(at index: UInt32) -> VirtioTransport? {
        guard index < count else { return nil }

        return slots[Int(index)]
    }

    /// Records one more transport, in its place, if it is one.
    ///
    /// Everything a later reader would have to trust is settled here, once: that
    /// the window is real and does not wrap, that it touches no other transport's
    /// registers, and that no two transports claim the same line. A blob that
    /// says otherwise is describing something this kernel will not delegate.
    @discardableResult
    public mutating func include(
        base address: UInt64,
        size width  : UInt64,
             line   : UInt32
    ) -> Bool {

        guard count < UInt32(Self.capacity),
              address != 0,
              width   != 0,
              width   <= UInt64(UInt32.max)
        else {
            rejected &+= 1
            return false
        }

        let (end, wrapped) = address.addingReportingOverflow(width)
        guard !wrapped else {
            rejected &+= 1
            return false
        }

        let entry = VirtioTransport(base: address, size: UInt32(width), line: line)

        for index in 0..<Int(count) {
            let other = slots[index]

            guard other.line != line,
                  address >= other.end || end <= other.base
            else {
                rejected &+= 1
                return false
            }
        }

        // Sorted insert. Thirty-two entries at boot, so the shuffle costs
        // nothing and buys an order the rest of the kernel can rely on.
        var at = Int(count)
        while at > 0, slots[at - 1].base > address {
            slots[at] = slots[at - 1]
            at -= 1
        }

        slots[at] = entry
        count &+= 1

        return true
    }
}
