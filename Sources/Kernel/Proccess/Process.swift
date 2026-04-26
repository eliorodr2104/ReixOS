//
//  Process.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/04/2026.
//

public typealias PID = UInt64

@frozen
public struct Process: ~Copyable {
    
    public let pid         : PID                              // Process ID
    public var status      : ProcessStatus                    // Current status
    public var addressSpace: AddressSpace                     // Virtual memory space
    public var priority    : UInt8                            // 0 ... 5 for ex
    public var type        : ProcessType                      // User | Kernel
    public var context     : UnsafeMutablePointer<TrapFrame>? // Used on Contex-Switch
    public var kernelStack : UnsafeMutableRawPointer?         // Use kmalloc()
    
    
    deinit {
        if let stack = self.kernelStack {
            KernelHeap.kfree(stack)
        }
    }
}
