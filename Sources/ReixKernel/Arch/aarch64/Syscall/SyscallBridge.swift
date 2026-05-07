//
//  SystemBridge.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

@_silgen_name("_asm_syscall")
internal func _asm_syscall_raw(_ type: UInt64, _ a1: UInt64, _ a2: UInt64, _ a3: UInt64)

@_silgen_name("_asm_syscall_ptr")
internal func _asm_syscall_ptr(_ type: UInt64, _ ptr: UnsafePointer<UInt8>, _ len: Int)

public func _syscall(_ type: SyscallNumber) {
    _asm_syscall_raw(type.rawValue, 0, 0, 0)
}

public func _syscall(_ type: SyscallNumber, _ arg1: UInt64) {
    _asm_syscall_raw(type.rawValue, arg1, 0, 0)
}

public func _syscall(_ type: SyscallNumber, _ text: String) {
    text.utf8.withContiguousStorageIfAvailable { buffer in
        _asm_syscall_ptr(type.rawValue, buffer.baseAddress!, buffer.count)
    }
}
