//
//  ShellProtocolBytes.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

// Little-endian reads and writes over the shell frame bytes. Every type in
// this protocol lays its fields out by hand, so these are shared.

@inline(__always)
func read16(
    _ bytes : UnsafePointer<UInt8>,
    _ offset: Int

) -> UInt16 { UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8) }

@inline(__always)
func read32(
    _ bytes : UnsafePointer<UInt8>,
    _ offset: Int
) -> UInt32 {
    UInt32(bytes[offset]) |
    (UInt32(bytes[offset + 1]) << 8) |
    (UInt32(bytes[offset + 2]) << 16) |
    (UInt32(bytes[offset + 3]) << 24)
}

@inline(__always)
func write16(
    _ bytes : UnsafeMutablePointer<UInt8>,
    _ offset: Int,
    _ value : UInt16
) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
}

@inline(__always)
func write32(
    _ bytes : UnsafeMutablePointer<UInt8>,
    _ offset: Int,
    _ value : UInt32
) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
}
