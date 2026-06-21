//
//  Process.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/04/2026.
//

import ReixABI

public typealias PID = UInt64

/// Hot state of a kernel-managed process.
///
/// Layout is tuned for the scheduler fast path: every field accessed on
/// every tick (status, priority, context, addressSpace, kernel stack)
/// stays inline. Cold fields (ELF image, exit code, waitingChildPid,
/// program break, ...) live in a separate `ProcessMetadata` allocation
/// pointed by `metadata`.
///
/// TODO: compact this struct further once the VMA chain is online and
/// we can profile real scheduler walks (consider bitfielding
/// status/priority/type into a single UInt32 word).
@frozen
public struct Process: RXEntry {

    public static var errorMessageAllocation = "Failed to allocate Process on the kernel heap"
    
    public var family        : ProcessRelations                      // 32 Byte -> (8 + 8 + 8 + 8)
    public var message       : Message? = nil                        // 21 Byte -> (4 * 4) + (4 + 1)
    public var addressSpace  : AddressSpace                          // 19 Byte -> ((1 + 8) + 8 + 2)
    
    
    public let pid           : PID                                   // 8 Byte
    public var context       : UnsafeMutablePointer<Arch.TrapFrame>? // 8 Byte
    
    
    /// Pointer to the cold metadata block. Implicit-unwrapped because the
    /// pointer is always populated immediately after `Process` is allocated
    /// by `ProcessManager.spawnProcess`; any access before that point is a
    /// programming error and crashes deterministically.
    public var metadata      : UnsafeMutablePointer<ProcessMetadata>! // 8 Byte
    public var kernelStackTop: UnsafeMutableRawPointer?               // 8 Byte
    public var kernelStackRaw: UnsafeMutableRawPointer?               // 8 Byte
    public var prev          : UnsafeMutablePointer<Self>?            // 8 Byte
    public var next          : UnsafeMutablePointer<Self>?            // 8 Byte
    public var replyTo       : UnsafeMutablePointer<Self>? = nil      // 8 Byte
    public var ipcDeadline   : UInt64?                     = nil      // 8 Byte
    
    
    public var ipcBadge      : Badge?                                 // 4 Byte
    public var pendingGrant  : UInt32?    = nil                       // 4 Byte
    
    public var status        : ProcessStatus                          // 9 Byte  -> (8 + 1) Enum with param
    public var priority      : UInt8                                  // 1 Byte
    public var depth         : UInt8                                  // 1 Byte
    public var type          : ProcessType                            // 1 Byte
    public var expectsReply  : Bool = false                           // 1 Byte
    public var pendingRights : CapRights? = nil
    
    
    
    public var entryID: UInt64 { pid }
    
    
    init(
        pid           : PID,
        status        : ProcessStatus    = .new,
        addressSpace  : AddressSpace,
        
        context       : UnsafeMutablePointer<Arch.TrapFrame>?,
        kernelStackTop: UnsafeMutableRawPointer?,
        kernelStackRaw: UnsafeMutableRawPointer?,
        family        : ProcessRelations = ProcessRelations(),
        
        type          : ProcessType      = .user,
        priority      : UInt8            = 1,
        depth         : UInt8            = 0,
        metadata      : UnsafeMutablePointer<ProcessMetadata>!
        
    ) {
        self.pid            = pid
        self.family         = family
        self.status         = status
        self.addressSpace   = addressSpace
        self.priority       = priority
        self.depth          = depth
        self.type           = type
        self.context        = context
        self.kernelStackTop = kernelStackTop
        self.kernelStackRaw = kernelStackRaw
        self.metadata       = metadata
    }
}
