//
//  SystemStats.swift
//  ReixOS
//
//  Created by Eliomar on 22/08/2026.
//


/// Machine-wide counters the kernel fills in for `procStats` sub-operation 0.
///
/// 56 bytes, aligned members in declaration order, so a syscall or an SHM
/// exporter can write it with one struct store and a userland reader can load
/// it back the same way.
///
/// The two stack figures are bytes ever *written* on the kernel's own stacks,
/// which is what `StackUsage` can observe and a lower bound on what was
/// reserved. `exceptionStackPeak` reads zero on any machine that never
/// panicked, because nothing else runs on that stack.
@frozen
public struct SystemStats {
    
    public var totalPages        : UInt64 = 0 // 0
    public var freePages         : UInt64 = 0 // 8
    public var systemTicks       : UInt64 = 0 // 16
    public var idleTime          : UInt64 = 0 // 24 counter units
    public var counterFreq       : UInt64 = 0 // 32
    public var traceLost         : UInt64 = 0 // 40
    public var kernelStackPeak   : UInt32 = 0 // 48
    public var exceptionStackPeak: UInt32 = 0 // 52
    
    public init() {}
}
