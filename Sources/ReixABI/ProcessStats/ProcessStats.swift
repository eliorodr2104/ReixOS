//
//  ProcessStats.swift
//  ReixOS
//
//  Created by Eliomar on 22/08/2026.
//


/// One process's snapshot, filled in for `procStats` sub-operation 1.
///
/// 48 bytes, byte-exact with the kernel writer. `status` is the process's
/// scheduler state, and `stackPages` the extent the user stack has grown to,
/// which is its high-water mark and not a current depth.
@frozen
public struct ProcessStats {
    
    public var pid          : UInt64 = 0                                   // 8 byte
    public var cpuTime      : UInt64 = 0                                   // 16 byte
    public var name         : InlineArray<16, UInt8> = .init(repeating: 0) // 32 byte
    public var scheduledAt  : UInt64 = 0                                   // 40 byte
    public var residentPages: UInt32 = 0                                   // 44 byte
    public var stackPages   : UInt16 = 0                                   // 46 byte
    public var status       : UInt8  = 0                                   // 47 byte
    public var nameLength   : UInt8  = 0                                   // 48 byte

    public init() {}
}
