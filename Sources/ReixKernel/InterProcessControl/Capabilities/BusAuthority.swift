//
//  BusAuthority.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

/// A whole bus: every transport window on it, and every line it can raise.
///
/// The authority a bus process holds so it can hand its children less. Nothing
/// may be driven through it directly: it is not a window and not a line, it is
/// the right to carve one out. `busDeriveDevice` and `busDeriveInterrupt` are
/// the only two things it does, and both narrow.
///
/// It exists because the alternative was the kernel probing transports to see
/// which were occupied, which is device knowledge in the one place that should
/// have none. The device tree can describe where a bus is; only a read can say
/// what sits on it, and reading is a driver's job.
public struct BusAuthority: RXObject {

    public static var errorMessageAllocation: StaticString = "Failed to allocate a bus authority on the kernel heap"

    /// First byte of the bus's register space, and its whole width.
    public var base: PhysicalAddress
    public var size: UInt64

    /// The block of interrupt lines the bus can raise, as INTIDs.
    public var firstLine: UInt32
    public var lineCount: UInt32

    public var references: UInt32


    public init(
        base     : PhysicalAddress,
        size     : UInt64,
        firstLine: UInt32,
        lineCount: UInt32
    ) {
        self.base       = base
        self.size       = size
        self.firstLine  = firstLine
        self.lineCount  = lineCount
        self.references = 0
    }


    /// Whether `[offset, offset + width)` lies inside this bus.
    public func covers(offset: UInt64, width: UInt64) -> Bool {
        guard width > 0, offset <= size else { return false }

        return size - offset >= width
    }

    /// The line the `index`th transport raises, counting from the base of the
    /// bus, or nil when the bus has no such transport.
    ///
    /// Transports are numbered from the base and their lines run alongside in
    /// the same order, which is the whole reason a bus is one range and not a
    /// list. Keeping the arithmetic here is what lets a bus process ask for the
    /// line of the slot it just read without knowing any interrupt numbers.
    public func line(at index: UInt32) -> UInt32? {
        guard index < lineCount else { return nil }

        return firstLine &+ index
    }
}
