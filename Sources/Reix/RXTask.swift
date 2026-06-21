//
//  RXTask.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.

import ReixABI

public typealias PID      = UInt64
public typealias ExitCode = UInt64


/// Raw layout written by `_asm_spawn` into the output buffer.
/// Two contiguous 64-bit words to match the `str x0/x1` stores exactly.
private struct SpawnResultRaw {
    var pid   : UInt64 = 0
    var handle: UInt64 = 0
}

/// Result handed back to userland: the child PID and the handle of the
/// endpoint the kernel seeded into BOTH parent and child at spawn time.
/// `handle == UInt32.max` means the process was spawned but no endpoint
/// could be installed (capsTable/endpoint table full).
public struct SpawnResult {
    public let pid   : PID
    public let handle: UInt32

    public var hasEndpoint: Bool { handle != UInt32.max }
}


@inline(__always)
public func exit(code: Int32) -> Never {
    _ = _syscall(.exit, UInt64(code))
    while true {  }
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
public func getParentPID() -> UInt64 {
    _syscall(.getParentPid)
}

@inline(__always)
public func parentEndpoint() -> UInt32? {
    let parentHandle = UInt32(truncatingIfNeeded: _syscall(.parentEndpoint))
    return parentHandle == UInt32.max ? nil : parentHandle
}

@inline(__always)
public func split() -> PID {
    _syscall(.split)
}

@inline(__always)
public func exec(path: StaticString) {
    // _syscall()
}

@inline(__always)
public func spawnProcess(path: StaticString) -> SpawnResult {

    var raw = SpawnResultRaw()

    withUnsafeMutablePointer(to: &raw) { ptr in
        _ = _asm_spawn_raw(
            SyscallNumber.spawnProcess.rawValue,
            UInt64(UInt(bitPattern: path.utf8Start)),
            UInt64(path.utf8CodeUnitCount),
            UnsafeMutableRawPointer(ptr)
        )
    }

    return SpawnResult(
        pid   : raw.pid,
        handle: UInt32(truncatingIfNeeded: raw.handle)
    )
}

@inline(__always)
public func spawnProcess() -> SpawnResult {
    
    var raw = SpawnResultRaw()

    withUnsafeMutablePointer(to: &raw) { ptr in
        _ = _asm_spawn_raw(
            SyscallNumber.spawnProcess.rawValue,
            0,
            0,
            UnsafeMutableRawPointer(ptr)
        )
    }
    
    

    return SpawnResult(
        pid   : raw.pid,
        handle: UInt32(truncatingIfNeeded: raw.handle)
    )
}


@inline(__always)
public func reapChild(for pid: PID) -> ExitCode {
    return _syscall(.reapChild, pid)
}

@inline(__always)
public func sleep(for value: Int) {
    return // _syscall()
}

@inline(__always)
public func terminate(
    pid : UInt64,
    type: TerminateType
) -> Bool {
    return false // _syscall(.terminate, pid, type) == 0
}


public enum TerminateType {
    case terminate
    case interrupt
    case kill
    case segmentationFault
    case illegalInstruction
    case arithmeticError
    case stackOverflow
    case badSyscall
    case abort(parent: PID)
    case suicide
}
