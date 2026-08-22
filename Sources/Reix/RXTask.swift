//
//  RXTask.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.

import ReixABI

public typealias PID = UInt64

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
public func spawnProcess(path: StaticString) -> SpawnResult {

    var raw = SpawnResultRaw()

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
        pid   : raw.pid,
        handle: UInt32(truncatingIfNeeded: raw.handle)
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

    var raw = SpawnResultRaw()

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
        pid   : raw.pid,
        handle: UInt32(truncatingIfNeeded: raw.handle)
    )
}


@inline(__always)
public func spawnProcess(
    path  : StaticString,
    grants: UnsafePointer<CapGrant>,
    count : Int
) -> SpawnResult {

    var raw = SpawnResultRaw()

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
