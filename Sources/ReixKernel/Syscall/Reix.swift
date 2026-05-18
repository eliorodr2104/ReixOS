//
//  Reix.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.

import RXSyscallCore

@inline(__always)
public func exit(code: Int32) {
    _ = _syscall(.exit, UInt64(code))
}

@inline(__always)
public func yield() {
    _ = _syscall(.yield)
}

@inline(__always)
public func getPID() -> UInt64 {
    _syscall(.getPid)
}

@inline(__always)
public func spawnProcess() -> UInt64 {
    return 0 // _syscall()
}

@inline(__always)
public func wait(pid: UInt64) -> UInt64 {
    return 0 // _syscall()
}

@inline(__always)
public func sleep(for value: Double) -> UInt64 {
    return 0 // _syscall(.getPid)
}
