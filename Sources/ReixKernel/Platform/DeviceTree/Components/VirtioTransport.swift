//
//  VirtioTransport.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

/// One virtio-mmio transport, exactly as the device tree declared it.
///
/// A window and the line that goes with it, kept as the blob said them and
/// never rounded or inferred. The pair travels together because a transport
/// whose line was worked out from its position on the bus is right on this
/// machine and wrong on the next.
public struct VirtioTransport {

    /// First byte of this transport's registers, and how many the blob declared.
    public var base: UInt64 = 0

    /// A transport window is an eighth of a page. `UInt32` rather than `UInt64`
    /// because there is no machine on which one is four gigabytes wide.
    public var size: UInt32 = 0

    /// The INTID this transport raises, as the GIC numbers them.
    public var line: UInt32 = 0

    public init() {}

    public init(base: UInt64, size: UInt32, line: UInt32) {
        self.base = base
        self.size = size
        self.line = line
    }

    /// One past the last byte. Never overflows: nothing gets in here without
    /// `VirtioBusInfo.include` having checked it first.
    public var end: UInt64 { base &+ UInt64(size) }
}
