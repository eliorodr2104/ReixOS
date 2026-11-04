//
//  DmaBuffer.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

/// A physically contiguous, non-cacheable buffer a device can transfer into or
/// out of: the capability `handle` naming it and the `address` it is mapped at
/// in *this* process.
///
/// The address a device's descriptor needs is not here on purpose. Ask for it
/// with `dmaPhysical` at the point you program the device, so the physical
/// address lives in one narrow place instead of being carried around in a
/// struct that gets copied and logged.
public struct DmaBuffer {
    public let handle : UInt32
    public let address: UInt64

    /// `true` when the buffer was allocated and mapped successfully.
    public var isValid: Bool { handle != UInt32.max }
}
