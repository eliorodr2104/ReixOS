//
//  Mem.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/06/2026.
//

@_cdecl("memcpy")
@_optimize(none)
public func memcpy(
    _ dst: UnsafeMutableRawPointer?,
    _ src: UnsafeRawPointer?,
    _ n  : UInt
) -> UnsafeMutableRawPointer? {
    guard let d = dst?.assumingMemoryBound(to: UInt8.self),
          let s = src?.assumingMemoryBound(to: UInt8.self) else { return dst }

    var i: UInt = 0
    while i < n { d[Int(i)] = s[Int(i)]; i &+= 1 }
    return dst
}

@_cdecl("memset")
@_optimize(none)
public func memset(
    _ s: UnsafeMutableRawPointer?,
    _ c: Int32,
    _ n: UInt
) -> UnsafeMutableRawPointer? {
    guard let p = s?.assumingMemoryBound(to: UInt8.self) else { return s }

    let byte = UInt8(truncatingIfNeeded: c)
    var i: UInt = 0
    while i < n { p[Int(i)] = byte; i &+= 1 }
    return s
}

@_cdecl("memmove")
@_optimize(none)
public func memmove(
    _ dst: UnsafeMutableRawPointer?,
    _ src: UnsafeRawPointer?,
    _ n  : UInt
) -> UnsafeMutableRawPointer? {
    guard let d = dst?.assumingMemoryBound(to: UInt8.self),
          let s = src?.assumingMemoryBound(to: UInt8.self) else { return dst }

    if UInt(bitPattern: d) < UInt(bitPattern: s) {
        var i: UInt = 0
        while i < n { d[Int(i)] = s[Int(i)]; i &+= 1 }
    } else if UInt(bitPattern: d) > UInt(bitPattern: s) {
        var i = n
        while i > 0 { i &-= 1; d[Int(i)] = s[Int(i)] }
    }
    return dst
}
