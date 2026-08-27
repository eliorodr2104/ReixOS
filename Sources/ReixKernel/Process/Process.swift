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
/// Layout is tuned for the scheduler fast path: `pid` through `status`
/// below are read or written on every `RoundRobin` rotation and every
/// `LinkedList` ready-queue push/pop, and land in the struct's first 64
/// bytes, one cache line. `priority` is not read anywhere yet: it just
/// rides in that line's trailing padding, in place for a scheduler that
/// weighs it, not because it is hot today. `kernelDeadline` follows
/// right after: it is polled on every timer tick by
/// `KernelDeadlineQueue.hasDue`, one line away from the rest of the hot
/// set instead of buried past `procStats`. Everything from `family` on
/// is cold: touched by IPC, address-space setup, or the `procStats`
/// tree walk, never by the tick path.
/// Cold fields (ELF image, exit code, waitingChildPid, program break, ...)
/// live in a separate `ProcessMetadata` allocation pointed by `metadata`.
///
/// - TODO: compact this struct further once the VMA chain is online and
/// we can profile real scheduler walks. `status` can't join a bitfield
/// word as-is: two of its cases carry a pointer payload. `priority`,
/// `depth` and `type` are the realistic bitfield candidates left.
@frozen
public struct Process: RXEntry {

    public static var errorMessageAllocation: StaticString = "Failed to allocate Process on the kernel heap"

    // MARK: - Hot, every scheduler rotation and ready-queue push/pop touches
    // these. Kept first so they share the struct's first cache line.
    public let pid           : PID                                    // 8 Byte
    public var context       : UnsafeMutablePointer<Arch.TrapFrame>?  // 8 Byte
    public var prev          : UnsafeMutablePointer<Self>?            // 8 Byte
    public var next          : UnsafeMutablePointer<Self>?            // 8 Byte

    /// Counter units this process has spent on the CPU, closed slices only.
    ///
    /// Charged by `RoundRobin.selectNextTask`, which is the one funnel every
    /// rotation goes through, so the value moves exactly once per slice. Raw
    /// `CNTVCT_EL0` units for `TraceEvent.timestamp`'s reason: the divisor is
    /// reported once by `procStats` and the conversion is the reader's.
    ///
    /// Inline rather than in `ProcessMetadata` because the scheduler writes it
    /// on every rotation, which is the definition this struct sorts on.
    public var cpuTime: UInt64 = 0                                     // 8 Byte

    /// The counter reading of the rotation that put this process on the CPU,
    /// `0` whenever it is not the running one.
    ///
    /// The open slice is therefore `now - scheduledAt`, which is what makes a
    /// live `cpuTime` readable without disturbing the scheduler: `procStats`
    /// adds it for the running process and every other one is already closed.
    public var scheduledAt: UInt64 = 0                                // 8 Byte

    public var status: ProcessStatus                                  // 9 Byte -> (8 + 1) Enum with param
    public var priority: UInt8                                        // 1 Byte

    // --- Warm: kernelDeadline is read on every timer tick by
    // KernelDeadlineQueue.hasDue; its siblings travel with it for arm/cancel.
    var kernelDeadline     : UInt64 = 0
    var kernelDeadlineOrder: UInt64 = 0
    var kernelDeadlineIndex: UInt16 = .max
    var kernelDeadlineKind : KernelDeadlineKind = .none

    // --- Cold from here down: family links, pending IPC state, address
    // space, cold metadata, IPC rendezvous partners, procStats bookkeeping.
    public var family: ProcessRelations // 32 Byte -> (8 + 8 + 8 + 8)

    /// The message this process is parked on a send queue with, if any.
    ///
    /// One optional rather than a payload plus a scatter of `pendingGrant` /
    /// `pendingRights` / `expectsReply` companions: those describe a single
    /// message, and keeping them separate meant every enqueue path had to
    /// remember to reset the ones it did not use. Never assign into it
    /// piecemeal: replace it whole, or retire it with `takePending`.
    public var pending     : PendingMessage? = nil // 32 Byte -> 21 + 4 + 5 + 1 + 1
    public var addressSpace: AddressSpace // 19 Byte -> ((1 + 8) + 8 + 2)

    /// Pointer to the cold metadata block. Implicit-unwrapped because the
    /// pointer is always populated immediately after `Process` is allocated
    /// by `ProcessManager.spawnProcess`; any access before that point is a
    /// programming error and crashes deterministically.
    public var metadata    : UnsafeMutablePointer<ProcessMetadata>!   // 8 Byte
    /// The newest caller waiting for this process to answer.
    ///
    /// One pointer, and it used to be the *only* record of a waiting caller: a
    /// server that took a second request before answering the first broke the
    /// first, which is why nothing in this system could ever have two requests
    /// in flight. Now it is the newest of possibly several, and the others are
    /// found the other way round, through their own `replyPartner`.
    public var replyTo     : UnsafeMutablePointer<Self>? = nil        // 8 Byte

    /// The process this one is waiting on for an answer, read off its status.
    ///
    /// Derived rather than stored, and that is the point: a process is waiting on
    /// somebody exactly when it is `.blockedOnReply`, so the two facts are one
    /// word and cannot contradict each other. Waking a caller clears it by
    /// clearing the status, which is what every wake already did.
    public var replyPartner: UnsafeMutablePointer<Self>? {
        if case .blockedOnReply(let server) = status { return server }
        return nil
    }

    /// The next caller waiting on the same server as this one, older than this.
    ///
    /// The callers of one server are a list threaded through the callers
    /// themselves: the server holds the newest in `replyTo` and each waiter
    /// points at the one behind it. So a server that holds eight requests costs
    /// nothing but the eight pointers its own callers were already carrying, and
    /// no process pays for a table it never uses.
    ///
    /// The other shape considered was a walk of the process tree, looking for
    /// whoever points here. It works, and it depends on the tree being built and
    /// on every waiter being reachable from init - a dependency that has no place
    /// in the path that wakes a caller whose server has died.
    public var nextWaiter: UnsafeMutablePointer<Self>? = nil

    /// How many callers are parked on this process besides `replyTo`.
    ///
    /// The length of that list, kept rather than counted because an unbounded
    /// number of parked callers is a queue with no backpressure. A server that
    /// takes requests and never answers them would hold callers for ever, and
    /// this is what makes that a bounded, visible failure instead.
    public var deferredReplies: UInt8 = 0

    @usableFromInline
    internal var procStatsParent: UnsafeMutablePointer<Self>? = nil
    
    @usableFromInline
    internal var procStatsLeft: UnsafeMutablePointer<Self>? = nil
    
    @usableFromInline
    internal var procStatsRight: UnsafeMutablePointer<Self>? = nil
    
    @usableFromInline
    internal var procStatsHeight: UInt8 = 1

    public let identity      : Identity                               // 4 Byte
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
        identity      : Identity,
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
