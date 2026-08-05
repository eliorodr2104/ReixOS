//
//  ProcStatsABI.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.

/// Machine-wide counters the kernel fills in for `procStats` sub-operation 0.
///
/// 48 bytes, every member an aligned `UInt64` in declaration order, so a
/// syscall or an SHM exporter can write it with one struct store and a
/// userland reader can load it back the same way.
@frozen
public struct SystemStats {
    
    public var totalPages : UInt64 = 0   // 0
    public var freePages  : UInt64 = 0   // 8
    public var systemTicks: UInt64 = 0   // 16
    public var idleTime   : UInt64 = 0   // 24  counter units
    public var counterFreq: UInt64 = 0   // 32
    public var traceLost  : UInt64 = 0   // 40
    
    public init() {}
}

/// One process's snapshot, filled in for `procStats` sub-operation 1.
///
/// 48 bytes, byte-exact with the kernel writer. `status` is the process's
/// scheduler state.
@frozen
public struct ProcessStats {
    
    public var pid          : UInt64 = 0                                   // 8 byte
    public var cpuTime      : UInt64 = 0                                   // 16 byte
    public var name         : InlineArray<16, UInt8> = .init(repeating: 0) // 32 byte
    public var scheduledAt  : UInt64 = 0                                   // 40 byte
    public var residentPages: UInt32 = 0                                   // 44 byte
    public var pad          : UInt16 = 0                                   // 46 byte
    public var status       : UInt8  = 0                                   // 47 byte
    public var nameLength   : UInt8  = 0                                   // 48 byte

    public init() {}
}

/// The wire values of `ProcessStats.status`, mirroring the kernel's
/// `ProcessStatus`. That enum cannot carry a raw value itself, since two of
/// its cases hold an endpoint pointer, so this is the ABI copy.
@frozen
public enum ProcessStatusCode: UInt8 {

    case new              = 0
    case ready            = 1
    case running          = 2
    case waiting          = 3
    case blockedOnSend    = 4
    case blockedOnReceive = 5
    case blockedOnReply   = 6
    case terminated       = 7
}
