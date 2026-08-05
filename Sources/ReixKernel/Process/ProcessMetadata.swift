//
//  ProcessMetadata.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/05/2026.
//


import ReixABI

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
public struct ProcessMetadata: RXAllocatable {

    public static var errorMessageAllocation: StaticString = "Failed to allocate ProcessMetadata on the kernel heap"
    
    public var capsTable: CapsTable         // (16 * 13) 208 Byte


    /// Handle of the bootstrap endpoint shared with the parent, as seen by
    /// THIS process. Seeded by the kernel at spawn time (`spawnEndpoint`);
    /// `nil` when the process has no parent channel. Read back from userland
    /// through the `parentEndpoint` syscall, so a freshly spawned child can
    /// discover its handle instead of assuming a fixed capsTable slot.
    public var parentEndpoint: UInt32?      // 4 Byte
    
    public var deviceCap     : UInt32?


    /// Current program break. Populated by the brk milestone (step 5);
    /// kept at zero until the VMA chain is wired so that any consumer
    /// reading it before step 5 sees a clearly invalid value.
    public var programBreak: VirtualAddress // 8 Byte

    
    /// Virtual base address where the lowest PT_LOAD segment was mapped.
    /// Used to walk the user page tables during teardown.
    public var elfLoadBase: UInt64          // 8 Byte
    

    /// Virtual end address of the highest PT_LOAD segment.
    public var elfLoadEnd : UInt64          // 8 Byte

    
    /// PID the process is currently waiting on through reapChild.
    /// `nil` when the process is not blocked on a child.
    public var waitingChildPid: PID?        // 8 Byte

    
    /// Exit code written by the exiting process. Read by the parent
    /// when reaping the zombie.
    public var exitReason: ExitReason?      // 4 Byte
    
    
    /// Backing physical page of the ELF image. Allocated by `ElfParser`,
    /// kept alive for the whole process lifetime, freed by the teardown.
    public var elfImage: PhysicalAddress?      // 8 Byte


    /// Human-readable name, the basename of the spawned image, truncated to
    /// the storage rather than to any path rule. Not NUL terminated.
    ///
    /// Inline bytes and not a pointer into the ELF image or the caller's path:
    /// both are gone or unmapped long before anything reads this, and the
    /// kernel has no allocator on the reporting path. Sixteen is what fits two
    /// trace payload words, so `TraceCode.procName` carries a whole name.
    public var name: InlineArray<16, UInt8>    // 16 Byte

    /// Bytes of `name` that are meaningful. Zero for a process nobody named,
    /// which is every process spawned before the name was assigned.
    public var nameLength: UInt8 = 0           // 1 Byte



    public init(
        elfImage       : PhysicalAddress?  = nil,
        elfLoadBase    : UInt64         = 0,
        elfLoadEnd     : UInt64         = 0,
        programBreak   : VirtualAddress = 0,
        waitingChildPid: PID?           = nil,
        exitReason     : ExitReason?    = nil
    ) {
        self.elfImage        = elfImage
        self.elfLoadBase     = elfLoadBase
        self.elfLoadEnd      = elfLoadEnd
        self.programBreak    = programBreak
        self.waitingChildPid = waitingChildPid
        self.exitReason      = exitReason
        self.capsTable       = CapsTable()
        self.parentEndpoint  = nil
        self.deviceCap       = nil
        self.name            = InlineArray<16, UInt8>(repeating: 0)
        self.nameLength      = 0
    }

    public init() {
        self.elfImage        = nil
        self.elfLoadBase     = 0
        self.elfLoadEnd      = 0
        self.programBreak    = 0
        self.waitingChildPid = nil
        self.exitReason      = nil
        self.capsTable       = CapsTable()
        self.parentEndpoint  = nil
        self.deviceCap       = nil
        self.name            = InlineArray<16, UInt8>(repeating: 0)
        self.nameLength      = 0
    }


    /// Copy at most `name`'s width out of `source` and record how much was
    /// taken, clamping a longer name rather than refusing it.
    ///
    /// The one writer of both fields, so a name and its length cannot disagree:
    /// every byte past what was copied is cleared, which is what lets the trace
    /// packing read all sixteen of them unconditionally.
    public mutating func setName(
        from source: UnsafePointer<UInt8>,
        count      : Int
    ) {
        let wanted = count < 0 ? 0 : count
        let taken  = wanted > name.count ? name.count : wanted

        for index in 0..<name.count {
            name[index] = index < taken ? source[index] : 0
        }

        nameLength = UInt8(truncatingIfNeeded: taken)
    }


    /// Copy another process's name verbatim, for a child that inherits its
    /// parent's image rather than loading one of its own.
    ///
    /// Through a pointer and not a value, because the source is always another
    /// heap-allocated metadata block and copying one to read sixteen bytes off
    /// it would carry the whole capability table with it.
    public mutating func setName(copyingFrom other: UnsafePointer<ProcessMetadata>) {
        for index in 0..<name.count {
            name[index] = other.pointee.name[index]
        }

        nameLength = other.pointee.nameLength
    }

}
