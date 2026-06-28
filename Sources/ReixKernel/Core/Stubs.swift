//
//  Stubs.swift
//  ReixOS
//
//  Freestanding runtime symbols the toolchain expects but that the kernel does
//  not really use: the stack-protector canary/handler and the libc allocation
//  and entropy hooks. Pure-Swift replacements for the former `Stubs.c`.
//

@_silgen_name("__stack_chk_guard")
public var __stack_chk_guard: UInt = 0x595e9fbd394d2c87

@_cdecl("__stack_chk_fail")
public func __stack_chk_fail() {
    while true {}
}

@_cdecl("free")
public func free(_ ptr: UnsafeMutableRawPointer?) {}

@_cdecl("posix_memalign")
public func posix_memalign(
    _ memptr   : UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
    _ alignment: Int,
    _ size     : Int
) -> Int32 {
    -1
}

@_cdecl("arc4random_buf")
public func arc4random_buf(_ buf: UnsafeMutableRawPointer?, _ nbytes: Int) {
    guard let p = buf?.assumingMemoryBound(to: UInt8.self) else { return }
    for i in 0..<nbytes { p[i] = 0x42 }
}
