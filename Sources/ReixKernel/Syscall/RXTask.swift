//
//  RKTask.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

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
