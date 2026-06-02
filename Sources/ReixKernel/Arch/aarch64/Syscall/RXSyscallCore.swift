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
    _ a3  : UInt64,
    _ a4  : UInt64,
    _ a5  : UInt64,
    _ a6  : UInt64,
    _ a7  : UInt64,
) -> UInt64

@_silgen_name("_asm_recv")
public func _asm_recv_raw(
    _ number: UInt64,
    _ handle: UInt64,
    _ buffer: UnsafeMutableRawPointer
) -> UInt64

@_silgen_name("_asm_recv_timeout")
public func _asm_recv_timeout_raw(
    _ number: UInt64,
    _ handle: UInt64,
    _ ticks : UInt64,
    _ buffer: UnsafeMutableRawPointer
) -> UInt64

@_silgen_name("_asm_call")
public func _asm_call_raw(
    _ number: UInt64,
    _ handle: UInt64,
    _ tag   : UInt64,
    _ word0 : UInt64,
    _ word1 : UInt64,
    _ word2 : UInt64,
    _ word3 : UInt64,
    _ buffer: UnsafeMutableRawPointer
) -> UInt64

@_silgen_name("_asm_spawn")
public func _asm_spawn_raw(
    _ number: UInt64,
    _ path  : UInt64,
    _ length: UInt64,
    _ buffer: UnsafeMutableRawPointer
) -> UInt64


public func _syscall(_ type: SyscallNumber) -> UInt64 {
    _asm_syscall_raw(type.rawValue, 0, 0, 0, 0, 0, 0, 0)
}

public func _syscall(
    _ type: SyscallNumber,
    _ arg1: UInt64
) -> UInt64 {
    _asm_syscall_raw(type.rawValue, arg1, 0, 0, 0, 0, 0, 0)
}

public func _syscall(
    _ type: SyscallNumber,
    _ arg1: UInt64,
    _ arg2: UInt64
) -> UInt64 {
    _asm_syscall_raw(type.rawValue, arg1, arg2, 0, 0, 0, 0, 0)
}


public func _syscall(
    _ type: SyscallNumber,
    _ arg1: UInt64,
    _ arg2: UInt64,
    _ arg3: UInt64,
    _ arg4: UInt64,
    _ arg5: UInt64,
    _ arg6: UInt64,
    _ arg7: UInt64,
) -> UInt64 {
    _asm_syscall_raw(
        type.rawValue,
        arg1,
        arg2,
        arg3,
        arg4,
        arg5,
        arg6,
        arg7
    )
}
