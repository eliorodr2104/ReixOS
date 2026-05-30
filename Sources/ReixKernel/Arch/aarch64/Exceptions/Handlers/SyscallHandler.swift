//
//  SyscallHandler.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

/// Dispatches user-space syscalls into kernel actions.
///
/// Holds the injected dependencies (process manager, scheduler) and
/// forwards each trap to the matching `SyscallProvider`. The actual
/// logic of every syscall lives in its own file under
/// `Arch/aarch64/Syscall/Providers/`, conforming to `SyscallProvider`.
/// The dispatcher is intentionally a single compile-time switch — no
/// existential indirection, no dynamic table.
public struct SyscallHandler {

    private let processManager: UnsafeMutablePointer<ProcessManager>
    private let scheduler     : UnsafeMutablePointer<KernelScheduler>

    public init(
        processManager: UnsafeMutablePointer<ProcessManager>,
        scheduler     : UnsafeMutablePointer<KernelScheduler>
    ) {
        self.processManager = processManager
        self.scheduler      = scheduler
    }

    public func handle(
        type : SyscallNumber,
        frame: UnsafeMutablePointer<Arch.TrapFrame>
    ) {
        let context = SyscallContext(
            processManager: processManager,
            scheduler     : scheduler
        )

        switch type {
            case .exit        : ExitSyscall        .handle(frame: frame, context: context)
            case .yield       : YieldSyscall       .handle(frame: frame, context: context)
            case .putchar     : PutcharSyscall     .handle(frame: frame, context: context)
            case .getPid      : GetPIDSyscall      .handle(frame: frame, context: context)
            case .reapChild   : ReapChildSyscall   .handle(frame: frame, context: context)
            case .spawnProcess: SpawnProcessSyscall.handle(frame: frame, context: context)
            case .brk         : BrkSyscall         .handle(frame: frame, context: context)
            case .mmap        : MmapSyscall        .handle(frame: frame, context: context)
            case .munmap      : MunmapSyscall      .handle(frame: frame, context: context)

            default: break
        }
    }
}
