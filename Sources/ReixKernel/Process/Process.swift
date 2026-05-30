//
//  Process.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/04/2026.
//

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

    public let pid    : PID
    public var family : ProcessRelations

    public var status      : ProcessStatus
    public var addressSpace: AddressSpace
    public var priority    : UInt8
    public var type        : ProcessType
    public var context     : UnsafeMutablePointer<Arch.TrapFrame>?

    public var kernelStackTop: UnsafeMutableRawPointer?
    public var kernelStackRaw: UnsafeMutableRawPointer?

    /// Pointer to the cold metadata block. Implicit-unwrapped because the
    /// pointer is always populated immediately after `Process` is allocated
    /// by `ProcessManager.spawnProcess`; any access before that point is a
    /// programming error and crashes deterministically.
    public var metadata: UnsafeMutablePointer<ProcessMetadata>!

    public var entryID: UInt64 { pid }

    public var prev  : UnsafeMutablePointer<Self>?
    public var next  : UnsafeMutablePointer<Self>?
}
