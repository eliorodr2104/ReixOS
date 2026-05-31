//
//  ProcessMetadata.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/05/2026.
//

/// Out-of-line cold state of a process.
///
/// Holds the fields that are not touched on the scheduler hot path
/// (context switch, ready-queue walk). Keeping them outside `Process`
/// preserves the cache locality of the hot struct: every additional
/// pointer chase against `metadata` is paid only on rare syscalls
/// (exit, reapChild, future brk/mmap) or during process teardown.
///
/// The instance is allocated on the kernel heap by `ProcessManager`
/// at spawn time and released at teardown.
@frozen
public struct ProcessMetadata: RXObject {

    public static var errorMessageAllocation = "Failed to allocate ProcessMetadata on the kernel heap"
    
    /// Backing physical page of the ELF image. Allocated by `ElfParser`,
    /// kept alive for the whole process lifetime, freed by the teardown.
    public var elfImage   : PhysicalPage?

    /// Virtual base address where the lowest PT_LOAD segment was mapped.
    /// Used to walk the user page tables during teardown.
    public var elfLoadBase: UInt64

    /// Virtual end address of the highest PT_LOAD segment.
    public var elfLoadEnd : UInt64

    /// Current program break. Populated by the brk milestone (step 5);
    /// kept at zero until the VMA chain is wired so that any consumer
    /// reading it before step 5 sees a clearly invalid value.
    public var programBreak: VirtualAddress

    /// PID the process is currently waiting on through reapChild.
    /// `nil` when the process is not blocked on a child.
    public var waitingChildPid: PID?

    /// Exit code written by the exiting process. Read by the parent
    /// when reaping the zombie.
    public var exitCode: UInt32?
    
    public var capsTable: CapsTable

    public init(
        elfImage       : PhysicalPage?  = nil,
        elfLoadBase    : UInt64         = 0,
        elfLoadEnd     : UInt64         = 0,
        programBreak   : VirtualAddress = 0,
        waitingChildPid: PID?           = nil,
        exitCode       : UInt32?        = nil
    ) {
        self.elfImage        = elfImage
        self.elfLoadBase     = elfLoadBase
        self.elfLoadEnd      = elfLoadEnd
        self.programBreak    = programBreak
        self.waitingChildPid = waitingChildPid
        self.exitCode        = exitCode
        self.capsTable       = CapsTable()
    }
    
    public init() {
        self.elfImage        = nil
        self.elfLoadBase     = 0
        self.elfLoadEnd      = 0
        self.programBreak    = 0
        self.waitingChildPid = nil
        self.exitCode        = nil
        self.capsTable       = CapsTable()
    }
    
}
