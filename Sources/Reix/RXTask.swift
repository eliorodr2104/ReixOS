//
//  RXTask.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.

import ReixABI

public typealias PID = UInt64

/// Raw layout written by `_asm_spawn` into the output buffer.
/// Two contiguous 64-bit words to match the `str x0/x1` stores exactly.
private struct TwoWordResultRaw {
    var first : UInt64 = 0
    var second: UInt64 = 0
}

@inline(__always)
private func twoWordSyscall(
    _ number: SyscallNumber,
    _ x0    : UInt64 = 0,
    _ x1    : UInt64 = 0,
    _ x2    : UInt64 = 0,
    _ x3    : UInt64 = 0
) -> TwoWordResultRaw {
    var raw = TwoWordResultRaw()

    withUnsafeMutablePointer(to: &raw) { ptr in
        _ = _asm_spawn_raw(
            number.rawValue,
            x0,
            x1,
            x2,
            x3,
            UnsafeMutableRawPointer(ptr)
        )
    }

    return raw
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
public func spawnProcess(path: StaticString) -> SpawnResult {

    var raw = TwoWordResultRaw()

    withUnsafeMutablePointer(to: &raw) { ptr in
        _ = _asm_spawn_raw(
            SyscallNumber.spawnProcess.rawValue,
            UInt64(UInt(bitPattern: path.utf8Start)),
            UInt64(path.utf8CodeUnitCount),
            0,
            0,
            UnsafeMutableRawPointer(ptr)
        )
    }

    return SpawnResult(
        pid   : raw.first,
        handle: UInt32(truncatingIfNeeded: raw.second)
    )
}

/// Spawn the image whose name is `length` bytes at `path`, seeded with `grants`.
///
/// The counterpart of the `StaticString` overloads, for a caller that read the
/// name at runtime instead of writing it into its own binary. Which is every
/// shell there has ever been.
@inline(__always)
public func spawnProcess(
    path  : UnsafePointer<UInt8>,
    length: Int,
    grants: UnsafePointer<CapGrant>,
    count : Int
) -> SpawnResult {

    var raw = TwoWordResultRaw()

    withUnsafeMutablePointer(to: &raw) { ptr in
        _ = _asm_spawn_raw(
            SyscallNumber.spawnProcess.rawValue,
            UInt64(UInt(bitPattern: path)),
            UInt64(length),
            UInt64(UInt(bitPattern: grants)),
            UInt64(count),
            UnsafeMutableRawPointer(ptr)
        )
    }

    return SpawnResult(
        pid   : raw.first,
        handle: UInt32(truncatingIfNeeded: raw.second)
    )
}


@inline(__always)
public func spawnProcess(
    path  : StaticString,
    grants: UnsafePointer<CapGrant>,
    count : Int
) -> SpawnResult {

    var raw = TwoWordResultRaw()

    withUnsafeMutablePointer(to: &raw) { ptr in
        _ = _asm_spawn_raw(
            SyscallNumber.spawnProcess.rawValue,
            UInt64(UInt(bitPattern: path.utf8Start)),
            UInt64(path.utf8CodeUnitCount),
            UInt64(UInt(bitPattern: grants)),
            UInt64(count),
            UnsafeMutableRawPointer(ptr)
        )
    }

    return SpawnResult(
        pid   : raw.first,
        handle: UInt32(truncatingIfNeeded: raw.second)
    )
}

@inline(__always)
public func spawnProcess() -> SpawnResult {

    var raw = TwoWordResultRaw()

    withUnsafeMutablePointer(to: &raw) { ptr in
        _ = _asm_spawn_raw(
            SyscallNumber.spawnProcess.rawValue,
            0,
            0,
            0,
            0,
            UnsafeMutableRawPointer(ptr)
        )
    }

    return SpawnResult(
        pid   : raw.first,
        handle: UInt32(truncatingIfNeeded: raw.second)
    )
}


@inline(__always)
public func reapChild(for pid: PID) -> ExitCode {
    return _syscall(.reapChild, pid)
}

/// Whether the principal a message's `identity` names is still running.
///
/// What a server asks before it goes on holding something for a client. A
/// process is never told that one of its clients has died, and the state it
/// keyed on that client's badge - a mapped window, a granted capability, a claim
/// on a file - would otherwise be held for the rest of the boot.
///
/// `false` is final: identities are never reused within a boot, so an answer of
/// no cannot become yes afterwards.
@inline(__always)
public func identityAlive(_ identity: UInt32) -> Bool {
    _syscall(.identityAlive, UInt64(identity)) != 0
}

/// Milliseconds in one scheduler tick.
///
/// The contract shared with the kernel
/// scheduler, so the two cannot drift out of sync.
private let millisecondsPerTick: UInt64 = SchedulerABI.millisecondsPerTick

/// Ticks in one second.
///
/// Derived from the tick length rather than written out, so the two cannot
/// disagree. A second is more ticks than a millisecond, so this multiplies
/// where the millisecond path divides.
private let ticksPerSecond: UInt64 = 1000 / millisecondsPerTick

public enum SleepModality {
    
    case milliseconds(UInt64)
    case seconds(UInt64)
    
}

/// Parks the caller for at least `milliseconds`, then returns `true`.
///
/// Rounds the deadline up, so any non-zero request waits at least one full
/// tick rather than silently becoming a plain yield. Returns `false` when
/// the kernel could not park the caller, the sleeper table is finite and
/// in that case no time has passed, so a caller that must wait has to retry
/// rather than assume it slept.
@inline(__always)
@discardableResult
public func sleep(for mode: SleepModality) -> Bool {
    
    var ticks: UInt64 = 0
    switch mode {
        case .milliseconds(let val):
            let whole     = val / millisecondsPerTick
            let remainder = val % millisecondsPerTick
            ticks         = remainder == 0 ? whole : whole + 1
            
        case .seconds(let val):
            
            let (product, overflowed) = val.multipliedReportingOverflow(
                by: ticksPerSecond
            )
            ticks = overflowed ? UInt64.max : product
    }
    
    

    return _syscall(.sleep, ticks) == 0
}

@inline(__always)
public func terminate(pid: PID) -> Bool {
    _syscall(.terminate, pid) == 0
}


// MARK: - Suspended tasks and stable jobs

/// Create an empty, unscheduled task plus the parent's bootstrap endpoint.
/// No user instruction can run until every region is sealed and `taskStart`
/// converts this task handle into a job handle in the same slot.
@inline(__always)
public func taskCreate() -> TaskCreation {
    let raw = twoWordSyscall(.taskCreate)
    return TaskCreation(
        task     : UInt32(truncatingIfNeeded: raw.first),
        bootstrap: UInt32(truncatingIfNeeded: raw.second)
    )
}

@inline(__always)
public func taskMapAnonymous(
    _ task    : UInt32,
    at address: UInt64,
    pages     : UInt32
) -> TaskResult {
    TaskResult(rawValue: _syscall(
        .taskMapAnonymous,
        UInt64(task),
        address,
        UInt64(pages)
    )) ?? .malformed
}

@inline(__always)
public func taskWrite(
    _ task    : UInt32,
    at address: UInt64,
    bytes     : UnsafeRawPointer,
    count     : Int
) -> TaskResult {
    guard count > 0 else { return .invalidRange }

    return TaskResult(rawValue: _syscall(
        .taskWrite,
        UInt64(task),
        address,
        UInt64(UInt(bitPattern: bytes)),
        UInt64(count)
    )) ?? .malformed
}

@inline(__always)
public func taskSealAndProtect(
    _ task     : UInt32,
    at address : UInt64,
    pages      : UInt32,
    permissions: TaskMemoryPermissions
) -> TaskResult {
    TaskResult(rawValue: _syscall(
        .taskSealAndProtect,
        UInt64(task),
        address,
        UInt64(pages),
        UInt64(permissions.rawValue)
    )) ?? .malformed
}

@inline(__always)
public func taskSetContext(
    _ task      : UInt32,
    entry       : UInt64,
    stack       : UInt64,
    programBreak: UInt64
) -> TaskResult {
    TaskResult(rawValue: _syscall(
        .taskSetContext,
        UInt64(task),
        entry,
        stack,
        programBreak
    )) ?? .malformed
}

/// Seal the construction phase. On success `task` is now a job handle; every
/// configuration right has disappeared before the scheduler sees the child.
@inline(__always)
public func taskStart(_ task: UInt32) -> TaskStartResult {
    let raw = twoWordSyscall(.taskStart, UInt64(task))
    return TaskStartResult(
        result: TaskResult(rawValue: raw.first) ?? .malformed,
        pid   : raw.second
    )
}

@inline(__always)
public func taskAbort(_ task: UInt32) -> TaskResult {
    TaskResult(rawValue: _syscall(.taskAbort, UInt64(task))) ?? .malformed
}

@inline(__always)
public func jobCancel(_ job: UInt32) -> TaskResult {
    TaskResult(rawValue: _syscall(.taskTerminate, UInt64(job))) ?? .malformed
}

@inline(__always)
public func jobStatus(_ job: UInt32) -> TaskStatus {
    let raw = twoWordSyscall(.taskStatus, UInt64(job))
    return TaskStatus(
        state   : TaskState(rawValue: raw.first) ?? .invalid,
        exitCode: raw.second
    )
}

/// Wait for a job without exposing its kernel PID. A kernel wait-set can
/// replace this bounded poll later without changing callers or the Job ABI.
public func waitForJob(
    _ job                         : UInt32,
    pollEveryMilliseconds interval: UInt64 = 10
) -> TaskStatus {
    while true {
        let status = jobStatus(job)
        switch status.state {
            case .configuring, .running:
                _ = sleep(for: .milliseconds(interval))
            case .exited, .aborted, .invalid:
                return status
        }
    }
}
