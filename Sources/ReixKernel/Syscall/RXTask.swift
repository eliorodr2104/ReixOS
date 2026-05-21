//
//  RXTask.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.

public typealias PID      = UInt64
public typealias ExitCode = UInt64


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
    _syscall(.getPid)
}

@inline(__always)
public func split() -> PID {
    return 0
}

@inline(__always)
public func exec(path: StaticString) {
    
}

@inline(__always)
public func spawnProcess(path: StaticString) -> UInt64 {
    return 0 // _syscall()
}

@inline(__always)
public func reapChild(for pid: PID) -> ExitCode {
    return _syscall(.reapChild, pid)
}

@inline(__always)
public func sleep(for value: Int) {
    return // _syscall(.getPid)
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
