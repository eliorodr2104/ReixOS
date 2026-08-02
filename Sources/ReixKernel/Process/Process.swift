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
/// every tick (status, priority, context, addressSpace) stays inline.
/// Cold fields (ELF image, exit code, waitingChildPid, program break, ...)
/// live in a separate `ProcessMetadata` allocation pointed by `metadata`.
///
/// - TODO: compact this struct further once the VMA chain is online and
/// we can profile real scheduler walks (consider bitfielding
/// status/priority/type into a single UInt32 word).
@frozen
public struct Process: RXEntry {

    public static var errorMessageAllocation: StaticString = "Failed to allocate Process on the kernel heap"
    
    public var family        : ProcessRelations                      // 32 Byte -> (8 + 8 + 8 + 8)

    /// The message this process is parked on a send queue with, if any.
    ///
    /// One optional rather than a payload plus a scatter of `pendingGrant` /
    /// `pendingRights` / `expectsReply` companions: those describe a single
    /// message, and keeping them separate meant every enqueue path had to
    /// remember to reset the ones it did not use. Never assign into it
    /// piecemeal: replace it whole, or retire it with `takePending`.
    public var pending       : PendingMessage? = nil                 // 32 Byte -> 21 + 4 + 5 + 1 + 1
    public var addressSpace  : AddressSpace                          // 19 Byte -> ((1 + 8) + 8 + 2)
    
    
    public let pid           : PID                                   // 8 Byte
    public var context       : UnsafeMutablePointer<Arch.TrapFrame>? // 8 Byte
    
    
    /// Pointer to the cold metadata block. Implicit-unwrapped because the
    /// pointer is always populated immediately after `Process` is allocated
    /// by `ProcessManager.spawnProcess`; any access before that point is a
    /// programming error and crashes deterministically.
    public var metadata      : UnsafeMutablePointer<ProcessMetadata>! // 8 Byte
    public var prev          : UnsafeMutablePointer<Self>?            // 8 Byte
    public var next          : UnsafeMutablePointer<Self>?            // 8 Byte
    public var replyTo       : UnsafeMutablePointer<Self>? = nil      // 8 Byte
    public var replyPartner  : UnsafeMutablePointer<Self>? = nil
    public var ipcDeadline   : UInt64?                     = nil      // 8 Byte
    
    
    public let identity      : Badge                                  // 4 Byte

    public var status        : ProcessStatus                          // 9 Byte  -> (8 + 1) Enum with param
    public var priority      : UInt8                                  // 1 Byte
    public var depth         : UInt8                                  // 1 Byte
    public var type          : ProcessType                            // 1 Byte



    public var entryID: UInt64 { pid }


    /// Hands the parked message over and leaves nothing behind.
    ///
    /// Delivery is the only reader, and it must not be able to deliver the same
    /// message twice or to clear half of it: taking the whole optional retires
    /// the payload, the grant, the session and the reply expectation together,
    /// so no fragment can survive into the next message this process parks.
    @inline(__always)
    public mutating func takePending() -> PendingMessage? {
        defer { pending = nil }

        return pending
    }

    
    init(
        pid           : PID,
        identity      : Badge,
        status        : ProcessStatus    = .new,
        addressSpace  : AddressSpace,
        
        context       : UnsafeMutablePointer<Arch.TrapFrame>?,
        family        : ProcessRelations = ProcessRelations(),
        
        type          : ProcessType      = .user,
        priority      : UInt8            = 1,
        depth         : UInt8            = 0,
        metadata      : UnsafeMutablePointer<ProcessMetadata>!
        
    ) {
        self.pid            = pid
        self.identity       = identity
        self.family         = family
        self.status         = status
        self.addressSpace   = addressSpace
        self.priority       = priority
        self.depth          = depth
        self.type           = type
        self.context        = context
        self.metadata       = metadata
    }
}
