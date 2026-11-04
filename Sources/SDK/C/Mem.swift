//
//  Mem.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/06/2026.
//

import MemoryPrimitives
import ReixABI

// Only a program image exports these: a host build of RawBytes at -Onone calls
// memcpy itself, so the host harnesses keep the platform's.
#if hasFeature(Embedded)
@_cdecl("memcpy")
public func memcpy(
    _ dst: UnsafeMutableRawPointer?,
    _ src: UnsafeRawPointer?,
    _ n  : UInt
) -> UnsafeMutableRawPointer? {
    guard let dst, let src else { return dst }

    RawBytes.copy(to: dst, from: src, count: Int(bitPattern: n))
    return dst
}

@_cdecl("memset")
public func memset(
    _ s: UnsafeMutableRawPointer?,
    _ c: Int32,
    _ n: UInt
) -> UnsafeMutableRawPointer? {
    guard let s else { return s }

    RawBytes.fill(s, with: UInt8(truncatingIfNeeded: c), count: Int(bitPattern: n))
    return s
}

/// Forward whenever the destination does not start inside the source.
@_cdecl("memmove")
public func memmove(
    _ dst: UnsafeMutableRawPointer?,
    _ src: UnsafeRawPointer?,
    _ n  : UInt
) -> UnsafeMutableRawPointer? {
    guard let dst, let src else { return dst }

    let distance = UInt(bitPattern: dst) &- UInt(bitPattern: src)
    guard distance != 0 else { return dst }

    if distance >= n {
        RawBytes.copy(to: dst, from: src, count: Int(bitPattern: n))
    } else {
        RawBytes.copyBackward(to: dst, from: src, count: Int(bitPattern: n))
    }
    return dst
}
#endif
