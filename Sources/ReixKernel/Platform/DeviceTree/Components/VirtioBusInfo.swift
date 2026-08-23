//
//  VirtioBusInfo.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

/// The extent of the virtio-mmio bus, as the device tree describes it.
///
/// Where the transports are and which lines they raise, and nothing about what
/// sits on them. The blob cannot say which slots are occupied and the kernel
/// does not ask: reading a device id is a driver's job, and the bus process
/// does it with a window carved from this.
public struct VirtioBusInfo {

    /// Lowest transport address seen, and the span up to the end of the highest.
    public var base: UInt64 = 0
    public var size: UInt64 = 0

    /// The block of INTIDs the transports raise, contiguous on this machine.
    public var firstLine: UInt32 = 0
    public var lineCount: UInt32 = 0

    public var isPresent: Bool { size != 0 && lineCount != 0 }

    /// Widens the extent to include one more transport.
    public mutating func include(
        base address: UInt64,
        size width  : UInt64,
             line   : UInt32
    ) {
        let end = address &+ width

        if base == 0 || address < base { base = address }
        if end > base &+ size { size = end &- base }

        if lineCount == 0 {
            firstLine = line
            lineCount = 1

        } else {
            let lowest  = min(firstLine, line)
            let highest = max(firstLine &+ lineCount &- 1, line)

            firstLine = lowest
            lineCount = highest &- lowest &+ 1
        }
    }

    public init() {}
}
