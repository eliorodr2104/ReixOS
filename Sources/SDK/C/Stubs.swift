//
//  Stubs.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/06/2026.
//

@_silgen_name("__stack_chk_guard")
public var __stack_chk_guard: UInt = 0xDEADC0DE

@_cdecl("__stack_chk_fail")
public func __stack_chk_fail() {
    while true {}
}

@_cdecl("arc4random_buf")
public func arc4random_buf(_ buf: UnsafeMutableRawPointer?, _ nbytes: Int) {
    guard let p = buf?.assumingMemoryBound(to: UInt8.self) else { return }
    for i in 0..<nbytes { p[i] = 0x42 }
}
