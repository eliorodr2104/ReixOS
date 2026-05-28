//
//  RXSyscallCore.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

@_silgen_name("_asm_syscall")
private func _asm_syscall_raw(
    _ type: UInt64,
    _ a1  : UInt64,
    _ a2  : UInt64,
    _ a3  : UInt64
) -> UInt64


public func _syscall(_ type: SyscallNumber) -> UInt64 {
    _asm_syscall_raw(type.rawValue, 0, 0, 0)
}

public func _syscall(
    _ type: SyscallNumber,
    _ arg1: UInt64
) -> UInt64 {
    _asm_syscall_raw(type.rawValue, arg1, 0, 0)
}

public func _syscall(
    _ type: SyscallNumber,
    _ arg1: UInt64,
    _ arg2: UInt64
) -> UInt64 {
    _asm_syscall_raw(type.rawValue, arg1, arg2, 0)
}
