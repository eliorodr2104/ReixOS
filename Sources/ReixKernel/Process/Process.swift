//
//  Process.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/04/2026.
//

public typealias PID = UInt64

@frozen
public struct Process: RXEntry {
    
    public let pid         : PID                                   // Process ID
    public var status      : ProcessStatus                         // Current status
    public var exitCode    : UInt32?
    public var addressSpace: AddressSpace                          // Virtual memory space
    public var priority    : UInt8                                 // 0 ... 5 for ex
    public var type        : ProcessType                           // User | Kernel
    public var context     : UnsafeMutablePointer<Arch.TrapFrame>? // Used on Contex-Switch
    public var kernelStack : UnsafeMutableRawPointer?              // Stack top
    public var kernelStackAllocation: UnsafeMutableRawPointer?
    public var userStack   : PhysicalPage?
    public var elfImage    : PhysicalPage?
    public var elfLoadBase : UInt64
    public var elfLoadEnd  : UInt64
    
    public var entryID: UInt64 { pid }
    
    public var back : UnsafeMutablePointer<Self>?
    public var next : UnsafeMutablePointer<Self>?
}
