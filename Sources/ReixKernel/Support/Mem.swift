//
//  Mem.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/06/2026.
//

import ReixABI

#if hasFeature(Embedded)
// Only the image exports the C names: a host build of RawBytes at -Onone calls
// memcpy itself, so there the platform's stays and the suites call the bodies.
@_cdecl("memcpy")
public func memcpy(_ dst: UnsafeMutableRawPointer?, _ src: UnsafeRawPointer?, _ n: UInt) -> UnsafeMutableRawPointer? {
    kernelMemcpy(dst, src, n)
}

@_cdecl("memset")
public func memset(_ s: UnsafeMutableRawPointer?, _ c: Int32, _ n: UInt) -> UnsafeMutableRawPointer? {
    kernelMemset(s, c, n)
}

@_cdecl("memmove")
public func memmove(_ dst: UnsafeMutableRawPointer?, _ src: UnsafeRawPointer?, _ n: UInt) -> UnsafeMutableRawPointer? {
    kernelMemmove(dst, src, n)
}
#endif

public func kernelMemcpy(
    _ dst: UnsafeMutableRawPointer?,
    _ src: UnsafeRawPointer?,
    _ n  : UInt
) -> UnsafeMutableRawPointer? {
    guard let dst, let src else { return dst }

    RawBytes.copy(to: dst, from: src, count: Int(bitPattern: n))
    return dst
}

public func kernelMemset(
    _ s: UnsafeMutableRawPointer?,
    _ c: Int32,
    _ n: UInt
) -> UnsafeMutableRawPointer? {
    guard let s else { return s }

    RawBytes.fill(s, with: UInt8(truncatingIfNeeded: c), count: Int(bitPattern: n))
    return s
}

/// Forward whenever the destination does not start inside the source.
public func kernelMemmove(
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

@_cdecl("memcmp")
@_optimize(none)
public func memcmp(
    _ a: UnsafeRawPointer?,
    _ b: UnsafeRawPointer?,
    _ n: UInt
) -> Int32 {
    guard let pa = a?.assumingMemoryBound(to: UInt8.self),
          let pb = b?.assumingMemoryBound(to: UInt8.self) else { return 0 }

    var i: UInt = 0
    while i < n {
        let ca = pa[Int(i)]
        let cb = pb[Int(i)]
        if ca != cb { return Int32(ca) - Int32(cb) }
        i &+= 1
    }
    return 0
}
